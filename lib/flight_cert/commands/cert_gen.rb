#==============================================================================
# Copyright (C) 2020-present Alces Flight Ltd.
#
# This file is part of FlightCert.
#
# This program and the accompanying materials are made available under
# the terms of the Eclipse Public License 2.0 which is available at
# <https://www.eclipse.org/legal/epl-2.0>, or alternative license
# terms made available by Alces Flight Ltd - please direct inquiries
# about licensing to licensing@alces-flight.com.
#
# FlightCert is distributed in the hope that it will be useful, but
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, EITHER EXPRESS OR
# IMPLIED INCLUDING, WITHOUT LIMITATION, ANY WARRANTIES OR CONDITIONS
# OF TITLE, NON-INFRINGEMENT, MERCHANTABILITY OR FITNESS FOR A
# PARTICULAR PURPOSE. See the Eclipse Public License 2.0 for more
# details.
#
# You should have received a copy of the Eclipse Public License 2.0
# along with FlightCert. If not, see:
#
#  https://opensource.org/licenses/EPL-2.0
#
# For more information on FlightCert, please visit:
# https://github.com/openflighthpc/flight-cert
#==============================================================================

require_relative '../self_signed_builder'
require 'shellwords'

module FlightCert
  module Commands
    class CertGen < Command
      def run
        process_options
        ensure_domain_is_set
        ensure_letsencrypt_has_an_email
        FlightCert.config.save_local_configuration

        if options.config_only
          puts "Configuration updated. Skipping certificate generation."
          return
        end

        # Generate the certificates
        FlightCert.config.letsencrypt? ? generate_letsencrypt : generate_selfsigned

        link_certificates

        # Attempts to restart the service
        if FlightCert.https_enabled?
          unless FlightCert.run_restart_command
            raise GeneralError, <<~ERROR.chomp
              Failed to restart the web server with the new certificate!
            ERROR
          end

        # Notifies the user how to enable https
        else
          $stderr.puts <<~WARN
            You can now enable the HTTPS server with:
            #{Paint["#{FlightCert.config.program_name} enable-https", :yellow]}
          WARN
        end
      end

      private

      ##
      # Updates the internal config with the new option flags
      def process_options
        all_cert_types = FlightCert::Configuration::ALL_CERT_TYPES
        if options.cert_type && all_cert_types.include?(options.cert_type)
          FlightCert.config.cert_type = options.cert_type
        elsif options.cert_type
          raise InputError, <<~ERROR.chomp
            Unrecognized certificate type: #{options.cert_type}
            Please select either: lets-encrypt or self-signed
          ERROR
        end

        # Updates the email field
        if options.email&.empty?
          $stderr.puts <<~ERROR.chomp
            Clearing the email setting...
          ERROR
          FlightCert.config.email = nil
        elsif options.email
          FlightCert.config.email = options.email
        end

        # Updates the domain field
        if options.domain&.empty?
          $stderr.puts <<~ERROR.chomp
            Clearing the domain setting...
          ERROR
          FlightCert.config.domain = nil
        elsif options.domain
          FlightCert.config.domain  = options.domain
        end
      end

      ##
      # Raises an error if the domain has not been set
      def ensure_domain_is_set
        domain = FlightCert.config.domain
        return if !(domain.nil? || domain.empty?)

        raise GeneralError, <<~ERROR.chomp
          A certificate can not be generated without a domain!
          Possibly try the following: #{Paint['--domain "$(hostname --fqdn)"', :yellow]}
        ERROR
      end

      ##
      # Errors if the email is unset for LetsEncrypt certificates
      def ensure_letsencrypt_has_an_email
        email = FlightCert.config.email
        return unless FlightCert.config.letsencrypt? && (email.nil? || email.empty?)
        puts <<~ERROR.chomp
          A Let's Encrypt certificates cannot be generated without an email!
          Please provide the following flag: #{Paint['--email EMAIL', :yellow]}
        ERROR
        exit 1
      end

      ##
      # Generates a lets encrypt certificate
      def generate_letsencrypt
        # Checks if the external service is running
        unless FlightCert.run_status_command
          msg = "The external web service does not appear to be running!"
          if FlightCert.config.start_command_prompt
            msg += "\nPlease start it with:\n#{Paint[FlightCert.config.start_command_prompt, :yellow]}"
          end
          raise GeneralError, msg
        end

        puts "Generating a Let's Encrypt certificate, please wait..."
        cmd = [
          FlightCert.config.certbot_bin,
          'certonly', '-n', '--agree-tos',
          '--domain', FlightCert.config.domain,
          '--email', FlightCert.config.email,
          *Shellwords.shellsplit(FlightCert.config.certbot_plugin_flags)
        ]
        FlightCert.logger.info "Command (approx): #{cmd.join(' ')}"
        out, err, status = Open3.capture3(*cmd)
        FlightCert.logger.info "Exited: #{status.exitstatus}"
        FlightCert.logger.debug "STDOUT: #{out}"
        FlightCert.logger.debug "STDERR: #{err}"
        if status.success?
          puts 'Certificate generated.'
        else
          raise GeneralError, <<~ERROR.chomp
            Failed to generate the Let's Encrypt certificate with the following error:

            #{err}
          ERROR
        end
      end

      ##
      # Generates a self signed certificate
      def generate_selfsigned
        puts "Generating a self-signed certificate with a 10 year expiry. Please wait..."
        builder = SelfSignedBuilder.new(FlightCert.config.domain, FlightCert.config.email)
        FileUtils.mkdir_p FlightCert.config.selfsigned_dir
        File.write        FlightCert.config.selfsigned_fullchain, builder.to_fullchain
        File.write        FlightCert.config.selfsigned_privkey,   builder.key.to_s
        puts 'Certificate generated.'
      end

      ##
      # Symlinks the relevant certificate/private key into the SSL directory
      def link_certificates
        ssl_privkey = FlightCert.config.ssl_privkey
        ssl_fullchain = FlightCert.config.ssl_fullchain

        privkey = FlightCert.config.letsencrypt? ?
          FlightCert.config.letsencrypt_privkey :
          FlightCert.config.selfsigned_privkey
        fullchain = FlightCert.config.letsencrypt? ?
          FlightCert.config.letsencrypt_fullchain :
          FlightCert.config.selfsigned_fullchain

        FileUtils.mkdir_p File.dirname(ssl_privkey)
        FileUtils.mkdir_p File.dirname(ssl_fullchain)
        FileUtils.ln_sf privkey, ssl_privkey
        FileUtils.ln_sf fullchain, ssl_fullchain
      end
    end
  end
end
