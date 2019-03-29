require 'omniauth'
require 'ruby-saml'

module OmniAuth
  module Strategies
    class MessageLogger #MC
      @@message_logger = Logger.new('log/saml_messages.log')
      @@message_logger.formatter = proc { |severity, datetime, progname, msg| "#{datetime}: #{msg}\n" }

      def self.log(string)
        @@message_logger.debug string
      end
    end

    class SAML
      include OmniAuth::Strategy

      def self.inherited(subclass)
        OmniAuth::Strategy.included(subclass)
      end

      OTHER_REQUEST_OPTIONS = [:skip_conditions, :allowed_clock_drift, :matches_request_id, :skip_subject_confirmation].freeze

      option :name_identifier_format, nil
      option :idp_sso_target_url_runtime_params, {}
      option :request_attributes, [
        { :name => 'email', :name_format => 'urn:oasis:names:tc:SAML:2.0:attrname-format:basic', :friendly_name => 'Email address' },
        { :name => 'name', :name_format => 'urn:oasis:names:tc:SAML:2.0:attrname-format:basic', :friendly_name => 'Full name' },
        { :name => 'first_name', :name_format => 'urn:oasis:names:tc:SAML:2.0:attrname-format:basic', :friendly_name => 'Given name' },
        { :name => 'last_name', :name_format => 'urn:oasis:names:tc:SAML:2.0:attrname-format:basic', :friendly_name => 'Family name' }
      ]
      option :attribute_service_name, 'Required attributes'
      option :attribute_statements, {
        name: ["name"],
        email: ["email", "mail"],
        first_name: ["first_name", "firstname", "firstName"],
        last_name: ["last_name", "lastname", "lastName"]
      }
      option :slo_default_relay_state
      option :uid_attribute
      option :idp_slo_session_destroy, proc { |_env, session| session.clear }

      def request_phase
if request.request_method == "POST" #MC make up for wrong metadata
request.env["PATH_INFO"] += "/callback"
return callback_phase
end
        options[:assertion_consumer_service_url] ||= callback_url
        runtime_request_parameters = options.delete(:idp_sso_target_url_runtime_params)

        additional_params = {}

        if runtime_request_parameters
          runtime_request_parameters.each_pair do |request_param_key, mapped_param_key|
            additional_params[mapped_param_key] = request.params[request_param_key.to_s] if request.params.has_key?(request_param_key.to_s)
          end
        end

        authn_request = OneLogin::RubySaml::Authrequest.new
        authn_requests_embed_sign = options.security.authn_requests_embed_sign #MC
        authn_requests_embed_sign = options.security.embed_sign if authn_requests_embed_sign.nil? #MC
        settings = OneLogin::RubySaml::Settings.new(options.merge(security: {embed_sign: authn_requests_embed_sign})) #MC

        redirect(authn_request.create(settings, additional_params))
      end

      def callback_phase
        raise OmniAuth::Strategies::SAML::ValidationError.new("SAML response missing") unless request.params["SAMLResponse"]

        # Call a fingerprint validation method if there's one
        if options.idp_cert_fingerprint_validator
          fingerprint_exists = options.idp_cert_fingerprint_validator[response_fingerprint]
          unless fingerprint_exists
            raise OmniAuth::Strategies::SAML::ValidationError.new("Non-existent fingerprint")
          end
          # id_cert_fingerprint becomes the given fingerprint if it exists
          options.idp_cert_fingerprint = fingerprint_exists
        end

        settings = OneLogin::RubySaml::Settings.new(options)

        # filter options to select only extra parameters
        opts = options.select {|k,_| OTHER_REQUEST_OPTIONS.include?(k.to_sym)}

        # symbolize keys without activeSupport/symbolize_keys (ruby-saml use symbols)
        opts =
          opts.inject({}) do |new_hash, (key, value)|
            new_hash[key.to_sym] = value
            new_hash
          end

        handle_response(request.params["SAMLResponse"], opts, settings) do
          super
        end

      rescue OmniAuth::Strategies::SAML::ValidationError
        fail!(:invalid_ticket, $!)
      rescue OneLogin::RubySaml::ValidationError
        fail!(:invalid_ticket, $!)
      end

      # Obtain an idp certificate fingerprint from the response.
      def response_fingerprint
        response = request.params["SAMLResponse"]
        response = (response =~ /^</) ? response : Base64.decode64(response)
        document = XMLSecurity::SignedDocument::new(response)
        cert_element = REXML::XPath.first(document, "//ds:X509Certificate", { "ds"=> 'http://www.w3.org/2000/09/xmldsig#' })
        base64_cert = cert_element.text
        cert_text = Base64.decode64(base64_cert)
        cert = OpenSSL::X509::Certificate.new(cert_text)
        Digest::SHA1.hexdigest(cert.to_der).upcase.scan(/../).join(':')
      end

      def other_phase
        if current_path.start_with?(request_path)
          @env['omniauth.strategy'] ||= self
          setup_phase
          settings = OneLogin::RubySaml::Settings.new(options)

          if on_subpath?(:metadata)
            # omniauth does not set the strategy on the other_phase
            response = OneLogin::RubySaml::Metadata.new

            if options.request_attributes.length > 0
              settings.attribute_consuming_service.service_name options.attribute_service_name
              settings.issuer = options.issuer

              options.request_attributes.each do |attribute|
                settings.attribute_consuming_service.add_attribute attribute
              end
            end

            Rack::Response.new(response.generate(settings), 200, { "Content-Type" => "application/xml" }).finish
          elsif on_subpath?(:slo)
            saml_soap_string = request_is_soapy? ? extract_saml_from_request : "" #MC
            if request.params["SAMLResponse"] || saml_soap_string.match(/LogoutResponse/) #MC
              message = request.params["SAMLResponse"] || saml_soap_string #MC
              message_log(location: :on_subpath_slo_saml_response, received: message) #MC 
              handle_logout_response(message, settings) #MC
            elsif request.params["SAMLRequest"] || saml_soap_string.match(/LogoutRequest/) #MC
              message = request.params["SAMLRequest"] || saml_soap_string #MC
              message_log(location: :on_subpath_slo_saml_request, received: message) #MC
              handle_logout_request(message, settings) #MC
            else
              raise OmniAuth::Strategies::SAML::ValidationError.new("SAML logout response/request missing")
            end
          elsif on_subpath?(:spslo)
            if options.idp_slo_target_url
              if settings.single_logout_service_binding =~ /SOAP/ #MC
                url = settings.idp_slo_target_url #MC
                body = soap_logout_request(settings)
                message_log(location: :on_subpath_spslo, sent: body.to_s) #MC
                res = soap_send(body.to_s, url) #MC
                #TODO: something with res? What if it's not 200?
                redirect(slo_relay_state) #MC
              else #MC
                redirect(generate_logout_request(settings))
              end #MC
            else
              Rack::Response.new("Not Implemented", 501, { "Content-Type" => "text/html" }).finish
            end
          else
            call_app!
          end
        else
          call_app!
        end
      end

      uid do
        if options.uid_attribute
          ret = find_attribute_by([options.uid_attribute])
          if ret.nil?
            raise OmniAuth::Strategies::SAML::ValidationError.new("SAML response missing '#{options.uid_attribute}' attribute")
          end
          ret
        else
          @name_id
        end
      end

      info do
        found_attributes = options.attribute_statements.map do |key, values|
          attribute = find_attribute_by(values)
          [key, attribute]
        end

        Hash[found_attributes]
      end

      extra { { :raw_info => @attributes, :response_object =>  @response_object } }

      def find_attribute_by(keys)
        keys.each do |key|
          return @attributes[key] if @attributes[key]
        end

        nil
      end

      private

      def message_log(params = {})
        return if Rails.env.production?
        direction = params.key?(:sent) ? :sent : :received
        MessageLogger.log("#{params[:location]}: #{direction}: #{params[direction]}")
      end

      def soap_slo_logout_response(settings, logout_request_id) #MC
        slo_logout_response = OneLogin::RubySaml::SloLogoutresponse.new()
        #lrs, settings.security.logout_responses_signed = [settings.security.logout_responses_signed, false]
        #response_doc = slo_logout_response.create_logout_response_xml_doc(settings, logout_request_id)
        #settings.security.logout_responses_signed = lrs
        #slo_logout_response.sign_document(response_doc, settings)
        slo_logout_response.create_logout_response_xml_doc(settings, logout_request_id)
      end

      def soap_parse(message) #MC
        Nokogiri::XML(message)
      end

      def soap_send(body, url) #MC
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        headers = {
          'Content-Type' => 'text/xml; charset=utf-8',
          'SOAPAction' => url
        }
        http.post(uri.path, body, headers)
      end

      def request_is_soapy? #MC
        request.content_type == "text/xml" && request.body.length > 100
      end

      def http_body_content #MC
        pos = request.body.pos
        request.body.rewind
        body = request.body.read
        request.body.seek(pos)
        body
      end

      def extract_saml_from_request #MC
        soap = soap_parse(http_body_content)
        saml_elements = soap.at_xpath('//saml2p:LogoutRequest|//saml2p:LogoutResponse', 'saml2p' => 'urn:oasis:names:tc:SAML:2.0:protocol')
        saml_elements.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
      end

      def on_subpath?(subpath)
        on_path?("#{request_path}/#{subpath}")
      end

      def handle_response(raw_response, opts, settings)
        response = OneLogin::RubySaml::Response.new(raw_response, opts.merge(settings: settings))
        response.attributes["fingerprint"] = options.idp_cert_fingerprint
        response.soft = false

        response.is_valid?
        @name_id = response.name_id
        @attributes = response.attributes
        @response_object = response
        message_log(location: :handle_response, received: response.decrypted_document) #MC

        if @name_id.nil? || @name_id.empty?
          raise OmniAuth::Strategies::SAML::ValidationError.new("SAML response missing 'name_id'")
        end

        session["sessionindex"] = response.sessionindex #MC
        session["saml_uid"] = @name_id
        yield
      end

      def slo_relay_state
        if request.params.has_key?("RelayState") && request.params["RelayState"] != ""
          request.params["RelayState"]
        else
          slo_default_relay_state = options.slo_default_relay_state
          if slo_default_relay_state.respond_to?(:call)
            if slo_default_relay_state.arity == 1
              slo_default_relay_state.call(request)
            else
              slo_default_relay_state.call
            end
          else
            slo_default_relay_state
          end
        end
      end

      def handle_logout_response(raw_response, settings)
        # After sending an SP initiated LogoutRequest to the IdP, we need to accept
        # the LogoutResponse, verify it, then actually delete our session.

        logout_response = OneLogin::RubySaml::Logoutresponse.new(raw_response, settings, :matches_request_id => session["saml_transaction_id"])
        logout_response.soft = true #MC false 
        logout_response.validate

        session.delete("saml_uid")
        session.delete("sessionindex")
        session.delete("saml_transaction_id")

        redirect(slo_relay_state)
      end

      def handle_logout_request(raw_request, settings)
        opts = { settings: settings }
        logout_request = OneLogin::RubySaml::SloLogoutrequest.new(raw_request, opts)

        if logout_request.is_valid? &&
          logout_request.name_id == session["saml_uid"]

          # Actually log out this session
          options[:idp_slo_session_destroy].call @env, session

          # Generate a response to the IdP.
          logout_request_id = logout_request.id
          if settings.single_logout_service_binding =~ /SOAP/ #MC
            response = soap_slo_logout_response(settings, logout_request_id)
            message_log(location: :handle_logout_response, sent: response.to_s) #MC 
            Rack::Response.new(response.to_s, 200, { "Content-Type" => "application/xml; charset=utf-8" }).finish #MC
          else #MC
            logout_response = OneLogin::RubySaml::SloLogoutresponse.new.create(settings, logout_request_id, nil, RelayState: slo_relay_state)
            redirect(logout_response)
          end #MC
        else
          raise OmniAuth::Strategies::SAML::ValidationError.new("SAML failed to process LogoutRequest")
        end
      end

      def soap_logout_request(settings) #MC
        logout_request = OneLogin::RubySaml::Logoutrequest.new()
        session[:transaction_id] = logout_request.uuid
        if settings.name_identifier_value.nil?
          settings.name_identifier_value = session[:userid]
        end
        #return logout_request.create_logout_request_xml_doc(settings, true)
        settings.sessionindex ||= session["sessionindex"] #MC
        lrs, settings.security.logout_requests_signed = [settings.security.logout_requests_signed, false]
        request_doc = logout_request.create_logout_request_xml_doc(settings)
        settings.security.logout_requests_signed = lrs
        encrypted_doc = logout_request.encrypt_document(request_doc, settings)
        logout_request.sign_document(encrypted_doc, settings)
      end

      # Create a SP initiated SLO: https://github.com/onelogin/ruby-saml#single-log-out
      def generate_logout_request(settings)
        logout_request = OneLogin::RubySaml::Logoutrequest.new()

        # Since we created a new SAML request, save the transaction_id
        # to compare it with the response we get back
        session["saml_transaction_id"] = logout_request.uuid

        settings.sessionindex ||= session["sessionindex"] #MC
        if settings.name_identifier_value.nil?
          settings.name_identifier_value = session["saml_uid"]
        end

        logout_request.create(settings, RelayState: slo_relay_state)
      end
    end
  end
end

OmniAuth.config.add_camelization 'saml', 'SAML'
