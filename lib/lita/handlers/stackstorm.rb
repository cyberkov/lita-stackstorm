require 'json'
require 'net/http'
require 'yaml'
require 'pry'
require 'ld-em-eventsource'
require 'lita/handlers/event_loop'

class Array
  def swap!(a, b)
    self[a], self[b] = self[b], self[a]
    self
  end
end

module Lita
  module Handlers
    class Stackstorm < Handler
      config :url, required: true
      config :username, required: true
      config :password, required: true
      config :auth_port, required: false, default: 9100
      config :execution_port, required: false, default: 9101
      config :emoji_icon, required: false, default: ':panda:'
      config :default_room, required: true, default: 'chatops'
      config :st2_route, required: true, default: 'lita'

      on :connected, :stream_listen

      class << self
        attr_accessor :token, :expires
        attr_accessor :loop
        attr_reader :stream
        attr_reader :ready_state
        attr_reader :retry

        @retry = 3
      end

      def self.config(_config)
        self.token = nil
        self.expires = nil
      end

      route /^st2 login$/, :login, command: false, help: { 'st2 login' => 'login with st2-api' }
      route /^st2 (ls|aliases|list)$/, :list, command: false, help: { 'st2 list' => 'list available st2 chatops commands' }
      route /^st2 connect$/, :stream_listen, command: true, help: {}

      route /^!(.*)$/, :call_alias, command: false, help: {}

      def direct_post(channel, message, user, _whisper = false)
        # case robot.config.robot.adapter
        # when :slack
        #  payload = {
        #    action: 'slack.chat.postMessage',
        #    parameters: {
        #      username: user,
        #      text: message,
        #      icon_emoji: config.emoji_icon,
        #      channel: channel
        #    }
        #  }
        #  make_post_request('/executions', payload)
        # else
        target = Lita::Source.new(user: Lita::User.fuzzy_find(user), room: Lita::Room.fuzzy_find(channel))
        robot.send_message(target, message)
        # end
      end

      def stream_listen(_payload)
        if _payload.respond_to?(:command?)
          if _payload.command?
            if EventLoop.running?
              _payload.reply "Stream Listener is running."
              return
            else
              _payload.reply "Stream Listener is NOT running."
            end
          end
        end

        Thread.new {
          EventLoop.run do
            listen
          end
        }.abort_on_exception=true
      end

      def listen
        log.info 'ST2 connecting to stream'
        authenticate if expired
        uri = "#{url_builder}/stream"
        stream_headers = headers
        stream_headers['Content-Type'] = 'application/x-yaml'
        log.debug stream_headers
        @conn = EM::EventSource.new(uri, nil, stream_headers)
        @conn.inactivity_timeout = 60

        @conn.message do |data|
          event = YAML.safe_load(data)
          log.debug "new message #{data}"
        end

        @conn.on "st2.announcement__chatops" do |data|
          log.debug "st2 event: #{data}"
          event = YAML.safe_load(data)
          direct_post(event['payload']['channel'],
                      event['payload']['message'],
                      event['payload']['user'],
                      event['payload']['whisper'])
        end

        @conn.open do
          log.info 'ST2 Stream connected.'
        end

        @conn.error do |error|
          log.error "error #{error}"
        end

        @conn.start
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
        resp = http(ssl: { verify: false }).post("#{auth_builder}/tokens") do |req|
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
          source_channel: (msg.message.source.room || config.default_room),
          notification_channel: config.st2_route
        }
        log.debug "Sending '#{payload}'"
        s = make_post_request('/aliasexecution', payload)
        robot.trigger(:st2_command_called)
        j = JSON.parse(s.body)
        if s.success?
          refurl = "#{config.url}/#/history/#{j['execution']['id']}/general"
          replies = [
            "I'll take it from here! Your execution ID for reference is %s",
            "Got it! Remember %s as your execution ID",
            "I'm on it! Your execution ID is %s",
            "Let me get right on that. Remember %s as your execution ID",
            "Always something with you. :) I'll take care of that. Your ID is %s",
            "I have it covered. Your execution ID is %s",
            "Let me start up the machine! Your execution ID is %s",
            "I'll throw that task in the oven and get cookin'! Your execution ID is %s",
            "Want me to take that off your hand? You got it! Don't forget your execution ID: %s",
            "River Tam will get it done with her psychic powers. Your execution ID is %s"
          ]
          msg.reply sprintf(replies.sample, refurl)
          #msg.reply "Got it! Details available at #{config.url}/#/history/#{j['execution']['id']}/general"
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
        resp = http(ssl: { verify: false }).get("#{url_builder}#{path}") do |req|
          req.headers = headers
          req.body = body.to_json unless body.empty?
        end
        resp
      end

      def make_post_request(path, body)
        resp = http(ssl: { verify: false }).post("#{url_builder}#{path}") do |req|
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
