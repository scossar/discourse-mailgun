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
      head '/mime', to: 'incoming_email#validate_url'
    end

    Discourse::Application.routes.append do
      mount ::Mandrill::Engine, at: '/mandrill'
    end

    class IncomingEmailController < ActionController::Base
      before_action :ensure_plugin_active

      def handle_mail
        mail_string = params["msg"]
        Email::Receiver.new(mail_string).process
        render text: "email was processed"
      end

      def validate_url
        render status: 200
      end


      def ensure_plugin_active
        if Discourse.disabled_plugin_names.include?(MANDRILL_PLUGIN_NAME)
          Rails.logger.warn("Mailgun plugin received email but plugin is disabled")

          # Returning status code 406 Not Acceptable prevents mandrill from
          # trying to deliver the same email again -  todo: confirm this is true
          head :not_acceptable
        end
      end
    end
  end
end

