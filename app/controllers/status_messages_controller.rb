#   Copyright (c) 2010-2011, Diaspora Inc.  This file is
#   licensed under the Affero General Public License version 3 or later.  See
#   the COPYRIGHT file.

class StatusMessagesController < ApplicationController
  before_filter :authenticate_user!

  before_filter :remove_getting_started, :only => [:create]

  use_bootstrap_for :bookmarklet

  respond_to :html,
             :mobile,
             :json

  include Privacy

  layout 'application', only: :bookmarklet

  # Called when a user clicks "Mention" on a profile page
  # @param person_id [Integer] The id of the person to be mentioned
  def new
    if params[:person_id] && @person = Person.where(:id => params[:person_id]).first
      @aspect = :profile
      @contact = current_user.contact_for(@person)
      @aspects_with_person = []
      if @contact
        @aspects_with_person = @contact.aspects
        @aspect_ids = @aspects_with_person.map{|x| x.id}
        gon.aspect_ids = @aspect_ids
        @contacts_of_contact = @contact.contacts
        render :layout => nil
      end
    elsif(request.format == :mobile)
      @aspect = :all
      @aspects = current_user.aspects
      @aspect_ids = @aspects.map{ |a| a.id }
      gon.aspect_ids = @aspect_ids
    else
      redirect_to stream_path
    end
  end

  def bookmarklet
    @aspects = current_user.aspects
    @aspect_ids = @aspects.map{|x| x.id}

    gon.preloads[:bookmarklet] = {
      content: params[:content],
      title: params[:title],
      url: params[:url],
      notes: params[:notes]
    }
  end

  def create
    params[:status_message][:aspect_ids] = [*params[:aspect_ids]]
    normalize_public_flag!
    services = [*params[:services]].compact

    @status_message = current_user.build_post(:status_message, params[:status_message])
    @status_message.build_location(:address => params[:location_address], :coordinates => params[:location_coords]) if params[:location_address].present?
    if params[:poll_question].present?
      @status_message.build_poll(:question => params[:poll_question])
      [*params[:poll_answers]].each do |poll_answer|
        @status_message.poll.poll_answers.build(:answer => poll_answer)
      end
    end


    @status_message.attach_photos_by_ids(params[:photos])


    # ------------------------ Added by me!!!!! ------------------------

    puts(current_user.username.to_s + " is posting")

    larva_monitor = true; # enable disable communication to LARVA monitor
    if larva_monitor
      puts "Communication with larva activated"
    else
      puts "Communication with larva deactivated"
    end

    checker = Privacy::Checker.new
    @violatedPeopleCount = checker.checkPolicies(params)    

    # Debugging - Check the user that had a violation of the policy
    if @violatedPeopleCount > 0
      puts @violatedPeopleCount.to_s + " policies violated"
    else
      # ------------- COMMUNICATION WITH LARVA -------------------------
      # if larva_monitor then
      if larva_monitor && params[:location_address].present? then
        policy_handler = Privacy::Checker.new
        ppl = Diaspora::Mentionable.people_from_string(params[:status_message][:text])

        ppl.each do |p|
          #Check whether the user has an evolving policy activated
          evolving_location_policy = PrivacyPolicy.where(:user_id => p.owner_id,
                                                         :shareable_type => "evolving-location",
                                                         :allowed_aspect => -1).first

          if evolving_location_policy != nil
            #If the evolving policy is activated communicate larva
            policy_handler.send_to_larva(p.owner_id,"post","Location",-1)
          end
        end
      else
        puts "The communication to the LARVA monitor is disabled"
      end
      # ------------- COMMUNICATION WITH LARVA -------------------------
    end
    # ------------------------ Added by me!!!!! ------------------------

    # If nobody's privacy policies were violated then the creation of the
    # status message continues as usual
    if @violatedPeopleCount == 0
      if @status_message.save
        aspects = current_user.aspects_from_ids(destination_aspect_ids)
        current_user.add_to_streams(@status_message, aspects)
        receiving_services = Service.titles(services)
        current_user.dispatch_post(@status_message, :url => short_post_url(@status_message.guid), :service_types => receiving_services)


        #this is done implicitly, somewhere else, but it doesnt work, says max. :'(
        @status_message.photos.each do |photo|
          current_user.dispatch_post(photo)
        end

        current_user.participate!(@status_message)

        if coming_from_profile_page? && !own_profile_page? # if this is a post coming from a profile page
          flash[:notice] = successful_mention_message
        end

        respond_to do |format|
          format.html { redirect_to :back }
          format.mobile { redirect_to stream_path }
          format.json { render :json => PostPresenter.new(@status_message, current_user), :status => 201 }
        end
      else
        respond_to do |format|
          format.html { redirect_to :back }
          format.mobile { redirect_to stream_path }
          format.json { render :nothing => true, :status => 403 }
        end
      end
    # If somebody's privacy policy has been violated we should inform the user
    # posting the status message about the fact that (s)he is violating other
    # users' privacy policies
    else
      # TODO: Print a message informing that the message was not created due
      # to a privacy policy violation
    end
  end

  private

  def destination_aspect_ids
    if params[:status_message][:public] || params[:status_message][:aspect_ids].first == "all_aspects"
      current_user.aspect_ids
    else
      params[:aspect_ids]
    end
  end

  def successful_mention_message
    t('status_messages.create.success', :names => @status_message.mentioned_people_names)
  end

  def coming_from_profile_page?
    request.env['HTTP_REFERER'].include?("people")
  end

  def own_profile_page?
    request.env['HTTP_REFERER'].include?("/people/" + params[:status_message][:author][:guid].to_s)
  end

  def normalize_public_flag!
    # mobile || desktop conditions
    sm = params[:status_message]
    public_flag = (sm[:aspect_ids] && sm[:aspect_ids].first == 'public') || sm[:public]
    public_flag.to_s.match(/(true)|(on)/) ? public_flag = true : public_flag = false
    params[:status_message][:public] = public_flag
    public_flag
  end

  def remove_getting_started
    current_user.disable_getting_started
  end
end
