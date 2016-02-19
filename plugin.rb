# name: Mandrill plugin
# about: Receives emails form Mandrill through HTTP post request
# version: 0.0.1
# authors: Andrea Bedini <andrea@andreabedini.com>

MANDRILL_PLUGIN_NAME ||= "mandrill".freeze

enabled_site_setting :mandrill_enabled

require 'openssl'

after_initialize do
  require_dependency 'email/receiver'

  module ::Mandrill
    class Engine < ::Rails::Engine
      engine_name MANDRILL_PLUGIN_NAME
      isolate_namespace Mandrill
    end

    Mandrill::Engine.routes.draw do
      post '/mime', to: 'incoming_email#handle_mail'
    end

    Discourse::Application.routes.append do
      mount ::Mandrill::Engine, at: '/mandrill'
    end

    class IncomingEmailController < ActionController::Base
      before_action :ensure_plugin_active
      before_action :verify_mandrill_token

      def handle_mail
        mail_string = params["body-mime"]
        begin
          Email::Receiver.new(mail_string).process
        rescue => e
          handle_failure(mail_string, e)
        end

        # We return 200 OK even if we failed to process the email. The email
        # was successfully delivered after all.
        head :ok
      end

      private

      def verify_mandrill_token
        unless verified_request?
          Rails.logger.warn("Unable to verify mailgun token authenticity")

          # If we can't verify the token we could presume that the request
          # wasn't originated from Mailgun. We still reply with the status 406
          # Not Acceptable that prevents mailgun from trying to deliver the
          # same email again.
          head :not_acceptable
        end
      end

      def verified_request?
        api_key = SiteSetting.mandrill_api_key

        token = params[:token]
        timestamp = params[:timestamp]
        signature = params[:signature]

        digest = OpenSSL::Digest::SHA256.new
        data = [timestamp, token].join
        signature == OpenSSL::HMAC.hexdigest(digest, api_key, data)
      end

      def ensure_plugin_active
        if Discourse.disabled_plugin_names.include?(MAILGUN_PLUGIN_NAME)
          Rails.logger.warn("Mailgun plugin received email but plugin is disabled")

          # Returning status code 406 Not Acceptable prevents mailgun from
          # trying to deliver the same email again
          head :not_acceptable
        end
      end

      # copied from app/jobs/scheduled/poll_mailbox.rb
      def handle_failure(mail_string, e)
        Rails.logger.warn("Email can not be processed: #{e}\n\n#{mail_string}") if SiteSetting.log_mail_processing_failures

        message_template = case e
                             when Email::Receiver::EmptyEmailError then
                               :email_reject_empty
                             when Email::Receiver::NoBodyDetectedError then
                               :email_reject_empty
                             when Email::Receiver::NoMessageIdError then
                               :email_reject_no_message_id
                             when Email::Receiver::AutoGeneratedEmailError then
                               :email_reject_auto_generated
                             when Email::Receiver::InactiveUserError then
                               :email_reject_inactive_user
                             when Email::Receiver::BlockedUserError then
                               :email_reject_blocked_user
                             when Email::Receiver::BadDestinationAddress then
                               :email_reject_bad_destination_address
                             when Email::Receiver::StrangersNotAllowedError then
                               :email_reject_strangers_not_allowed
                             when Email::Receiver::InsufficientTrustLevelError then
                               :email_reject_insufficient_trust_level
                             when Email::Receiver::ReplyUserNotMatchingError then
                               :email_reject_reply_user_not_matching
                             when Email::Receiver::TopicNotFoundError then
                               :email_reject_topic_not_found
                             when Email::Receiver::TopicClosedError then
                               :email_reject_topic_closed
                             when Email::Receiver::InvalidPost then
                               :email_reject_invalid_post
                             when ActiveRecord::Rollback then
                               :email_reject_invalid_post
                             when Email::Receiver::InvalidPostAction then
                               :email_reject_invalid_post_action
                             when Discourse::InvalidAccess then
                               :email_reject_invalid_access
                           end

        template_args = {}

        # there might be more information available in the exception
        if message_template == :email_reject_invalid_post && e.message.size > 6
          message_template = :email_reject_invalid_post_specified
          template_args[:post_error] = e.message
        end

        if message_template
          # inform the user about the rejection
          message = Mail::Message.new(mail_string)
          template_args[:former_title] = message.subject
          template_args[:destination] = message.to
          template_args[:site_name] = SiteSetting.title

          client_message = RejectionMailer.send_rejection(message_template, message.from, template_args)
          Email::Sender.new(client_message, message_template).send
        else
          Discourse.handle_job_exception(e, error_context(@args, "Unrecognized error type when processing incoming email", mail: mail_string))
        end
      end

    end
  end
end

