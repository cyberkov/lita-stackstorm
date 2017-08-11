require 'json'
require 'net/http'
require 'yaml'
require 'pry'

class Array
  def swap!(a, b)
    self[a], self[b] = self[b], self[a]
    self
  end
end

module Lita
  module Handlers
    class Stackstorm < Handler
      # insert handler code here

      config :url, required: true
      config :username, required: true
      config :password, required: true
      config :auth_port, required: false, default: 9100
      config :execution_port, required: false, default: 9101
      config :emoji_icon, required: false, default: ':panda:'

      on :connected, :stream_listen

      class << self
        attr_accessor :token, :expires
      end

      def self.config(_config)
        self.token = nil
        self.expires = nil
      end

      route /^st2 login$/, :login, command: false, help: { 'st2 login' => 'login with st2-api' }
      route /^st2 (ls|aliases|list)$/, :list, command: false, help: { 'st2 list' => 'list available st2 chatops commands' }
      route /^st2 connect$/, :stream_listen, command: false, help: { 'st2 connect' => 'connect to eventstream' }

      route /^!(.*)$/, :call_alias, command: false, help: {}

      def direct_post(channel, message, user)
        case robot.config.robot.adapter
        when :slack
          payload = {
            action: 'slack.chat.postMessage',
            parameters: {
              username: user,
              text: message,
              icon_emoji: config.emoji_icon,
              channel: channel
            }
          }
          make_post_request('/executions', payload)
        else
          target = Lita::Source.new(user: user, room: Lita::Room.fuzzy_find(channel))
          robot.send_message(target, message)
        end
      end

      def stream_listen(_payload)
        authenticate if expired
        uri = URI("#{url_builder}/stream")
        log.debug "ST2 connecting"
        Thread.new do
          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
            request = Net::HTTP::Get.new uri
            request['X-Auth-Token'] = headers['X-Auth-Token']
            request['Content-Type'] = 'application/x-yaml'
            http.request request do |response|
              io = StringIO.new
              log.debug "ST2 connected"
              response.read_body do |chunk|
                c = chunk.strip
                unless c.empty?
                  io.write chunk
                  event = YAML.safe_load(io.string)
                  if event['event'] =~ /st2\.announcement/
                    direct_post(event['data']['payload']['channel'],
                                event['data']['payload']['message'],
                                event['data']['payload']['user'])
                  end
                  io.reopen('')
                end
              end
            end
          end
        end
      end

      def auth_builder
        if (Integer(config.auth_port) == 443) && config.url.start_with?('https')
          "#{config.url}/auth"
        else
          "#{config.url}:#{config.auth_port}/v1"
        end
      end

      def url_builder
        if (Integer(config.execution_port) == 443) && config.url.start_with?('https')
          "#{config.url}/api"
        else
          "#{config.url}:#{config.execution_port}/v1"
        end
      end

      def authenticate
        resp = http.post("#{auth_builder}/tokens") do |req|
          req.body = {}
          req.headers['Authorization'] = http.set_authorization_header(:basic_auth, config.username, config.password)
        end
        self.class.token = JSON.parse(resp.body)['token']
        self.class.expires = JSON.parse(resp.body)['expiry']
        resp
      end

      def call_alias(msg)
        authenticate if expired
        command = msg.matches.flatten.first
        found = ''
        redis.scan_each do |a|
          possible = /#{a}/.match(command)
          unless possible.nil?
            found = a
            break
          end
        end

        if found.empty?
          msg.reply "I couldn't find a command for '#{command}'. sorry."
          return
        end

        jobject = JSON.parse(redis.get(found))
        payload = {
          name: jobject['object']['name'],
          format: jobject['format'],
          command: command,
          user: msg.user.name,
          source_channel: 'chatops',
          notification_channel: 'lita'
        }
        s = make_post_request('/aliasexecution', payload)
        j = JSON.parse(s.body)
        if s.success?
          msg.reply "Got it! Details available at #{config.url}/#/history/#{j['execution']['id']}/general"
        else
          msg.reply "Execution failed with message: #{j['faultstring']}"
        end
      end

      def list(msg)
        authenticate if expired
        redis.keys.each { |k| redis.del k }
        s = make_request('/actionalias', '')
        if JSON.parse(s.body).empty?
          msg.reply 'No Action Aliases Registered'
        else
          j = JSON.parse(s.body)
          a = ''
          j.take_while { |i| i['enabled'] }.each do |command|
            # convert each representation to a regular expression
            command['formats'].each do |format|
              if format.is_a? Hash
                if format.key?('representation')
                  format['representation'].each do |rep|
                    f = convert_to_regex(rep)
                    redis.set(f, { format: rep, object: command }.to_json)
                    a += "#{format['display']} -> #{command['description']}\n"
                  end
                else
                  f = convert_to_regex(format['display'])
                  redis.set(f, { format: format['display'], object: command }.to_json)
                  a += "#{format['display']} -> #{command['description']}\n"
                end

              elsif format.is_a? String
                f = convert_to_regex(format)
                redis.set(f, { format: format, object: command }.to_json)
                a += "#{format} -> #{command['description']}\n"
              else
                next
              end
            end
          end
          msg.reply a
        end
      end

      def convert_to_regex(format)
        extra_params = '(\\s+(\\S+)\\s*=("([\\s\\S]*?)"|\'([\\s\\S]*?)\'|({[\\s\\S]*?})|(\\S+))\\s*)*'
        f = format.gsub(/(\s*){{\s*\S+\s*=\s*(?:({.+?}|.+?))\s*}}(\s*)/, '\\s*([\\S]+)?\\s*')
        f = f.gsub(/\s*{{.+?}}\s*/, '\\s*([\\S]+?)\\s*')
        f = "^\\s*#{f}#{extra_params}\\s*$"
        f
      end

      def login(msg)
        http_resp = authenticate
        if ![200, 201, 280].index(http_resp.status).nil?
          msg.reply "login successful\ntoken: #{self.class.token}"
        elsif http_resp.status == 500
          msg.reply "#{http_resp.status}: login failed!!"
        else
          msg.reply "#{http_resp.status}: login failed!!"
        end
      end

      def expired
        self.class.token.nil? || Time.now >= Time.parse(self.class.expires)
      end

      def make_request(path, body)
        resp = http.get("#{url_builder}#{path}") do |req|
          req.headers = headers
          req.body = body.to_json unless body.empty?
        end
        resp
      end

      def make_post_request(path, body)
        resp = http.post("#{url_builder}#{path}") do |req|
          req.body = {}
          req.headers = headers
          req.body = body.to_json
        end
        resp
      end

      def headers
        headers = {}
        headers['Content-Type'] = 'application/json'
        headers['X-Auth-Token'] = self.class.token.to_s
        headers
      end

      Lita.register_handler(self)
    end
  end
end
