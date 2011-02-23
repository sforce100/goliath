module Goliath
  # @private
  class Request
    include Constants
    attr_accessor :app, :conn, :env, :response, :body

    def initialize(app, conn, env)
      @app  = app
      @conn = conn
      @env  = env

      @response = Goliath::Response.new
      @body = StringIO.new(INITIAL_BODY.dup)
      @env[RACK_INPUT] = body

      # @env[ASYNC_CLOSE]    = EM::DefaultDeferrable.new
      @env[ASYNC_CALLBACK] = method(:post_process)

      @env[STREAM_SEND]  = proc { @conn.send_data(data) }
      @env[STREAM_CLOSE] = proc { @conn.terminate_connection }
      @env[STREAM_START] = proc do
        @conn.send_data(@response.head)
        @conn.send_data(@response.headers_output)
      end

      @state = :processing
    end

    def parse_header(h, parser)
      h.each do |k, v|
        @env[HTTP_PREFIX + k.gsub('-','_').upcase] = v
      end

      @env[STATUS]          = parser.status_code
      @env[REQUEST_METHOD]  = parser.http_method
      @env[REQUEST_URI]     = parser.request_url
      @env[QUERY_STRING]    = parser.query_string
      @env[HTTP_VERSION]    = parser.http_version.join('.')
      @env[SCRIPT_NAME]     = parser.request_path
      @env[REQUEST_PATH]    = parser.request_path
      @env[PATH_INFO]       = parser.request_path
      @env[FRAGMENT]        = parser.fragment
    end

    def parse(data)
      @body << data
    end

    def finished?
      @state == :finished
    end

    # def succeed
    # @env[ASYNC_CLOSE].succeed if @env[ASYNC_CLOSE]
    # end

    #
    # Request processing
    #

    def process
      begin
        @state = :finished
        post_process(@app.call(@env))

      rescue Exception => e
        server_exception(e)
      end
    end

    def post_process(results)
      begin
        status, headers, body = results
        return if status && status == Goliath::Connection::AsyncResponse.first

        @response.status, @response.headers, @response.body = status, headers, body
        @response.each { |chunk| @conn.send_data(chunk) }
        @env[LOGGER].info("Status: #{@response.status}, " +
                          "Content-Length: #{@response.headers['Content-Length']}, " +
                          "Response Time: #{"%.2f" % ((Time.now.to_f - @env[:start_time]) * 1000)}ms")

        @conn.terminate_connection if !keep_alive?

      rescue Exception => e
        server_exception(e)
      end
    end

    private

      def server_exception(e)
        @env[LOGGER].error("#{e.message}\n#{e.backtrace.join("\n")}")
        post_process([500, {}, 'An error happened'])
      end

      def keep_alive?
        case @env[HTTP_VERSION]
          # HTTP 1.1: all requests are persistent requests, client
          # must send a Connection:close header to indicate otherwise
          when '1.1' then
            (@env[HTTP_PREFIX + CONNECTION].downcase != 'close') rescue true

            # HTTP 1.0: all requests are non keep-alive, client must
            # send a Connection: Keep-Alive to indicate otherwise
          when '1.0' then
            (@env[HTTP_PREFIX + CONNECTION].downcase == 'keep-alive') rescue false
        end
      end

  end
end