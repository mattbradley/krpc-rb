require 'krpc/connection'
require 'krpc/service'
require 'krpc/types'
require 'krpc/encoder'
require 'krpc/decoder'
require 'krpc/streaming'
require 'krpc/error'
require 'krpc/core_extensions'
require 'krpc/krpc.pb'

module KRPC
  
  ##
  # A kRPC client, through which all Remote Procedure Calls are made. To make RPC calls client 
  # must first connect to server. This can be achieved by calling Client#connect or Client#connect!
  # methods. Client object can connect and disconnect from the server many times during it's 
  # lifetime. RPCs can be made by calling Client#execute_rpc method. After generating services API (with
  # Client#generate_services_api! call), RPCs can be also made using
  # `client.service_name.procedure_name(parameter, ...)`
  #
  # ### Example:
  #     client = KRPC::Client.new(name: "my client").connect!
  #     ctrl = client.space_center.active_vessel.control
  #     ctrl.activate_next_stage
  #     ctrl.throttle = 1 # Full ahead!
  #     client.close # Gracefully disconnect - and allow the spacecraft to crash ;)
  #     client.connect do # Connect to server again
  #       client.space_center.active_vessel.control.throttle = 0 # Save the spacecraft from imminent destruction ;)
  #     end # Gracefully disconnect
  class Client
    DEFAULT_NAME = ""

    include Doc::SuffixMethods

    attr_reader :name, :rpc_connection, :stream_connection, :streams_manager, :krpc

    # Create new Client object, optionally specifying IP address and port numbers on witch kRPC 
    # server is listening and the name for this client (up to 32 bytes of UTF-8 encoded text).
    def initialize(name: DEFAULT_NAME, host: Connection::DEFAULT_SERVER_HOST, rpc_port: Connection::DEFAULT_SERVER_RPC_PORT, stream_port: Connection::DEFAULT_SERVER_STREAM_PORT)
      @name = name
      @rpc_connection = RPCConnection.new(name, host, rpc_port)
      @stream_connection = StreamConnection.new(rpc_connection, host, stream_port)
      @streams_manager = Streaming::StreamsManager.new(self)
      @services = {}
      @krpc = Services::KRPC.new(self)
      Doc.add_docstring_info(false, self.class, "krpc", return_type: @krpc.class, xmldoc: "<doc><summary>Core kRPC service, e.g. for querying for the available services. Most of this functionality is used internally by the Ruby client and therefore does not need to be used directly from application code.</summary></doc>")
    end
    
    # Connect to a kRPC server on the IP address and port numbers specified during this client
    # object creation and return `self`. Calling this method while the client is already connected
    # will raise an exception. If the block is given, then it's called passing `self` and the 
    # connection to kRPC server is closed at the end of the block.
    def connect(&block)
      rpc_connection.connect
      stream_connection.connect
      streams_manager.start_streaming_thread
      call_block_and_close(block) if block_given?
      self
    end
    
    # Connect to a kRPC server, generate services API and return `self`. Shorthand for calling 
    # Client#connect and Client#generate_services_api! subsequently. If the block is given, then 
    # it's called passing `self` and the connection to kRPC server is closed at the end of the block.
    def connect!(&block)
      connect
      generate_services_api!
      call_block_and_close(block) if block_given?
      self
    end
    
    # Close connection to kRPC server. Returns `true` if the connection has closed or `false` if 
    # the client had been already disconnected.
    def close
      streams_manager.remove_all_streams
      streams_manager.stop_streaming_thread
      stream_connection.close
      rpc_connection.close
    end

    # Returns `true` if the client is connected to a server, `false` otherwise.
    def connected?
      rpc_connection.connected?
    end
      
    # Interrogates the server to find out what functionality it provides and dynamically creates 
    # all of the classes and methods that form services API. For each service that server provides:
    # 
    # 1. Class `KRPC::Services::{service name here}`, and module `KRPC::Gen::{service name here}`
    #    are created.
    # 2. `KRPC::Gen::{service name here}` module is filled with dynamically created classes.
    # 3. Those classes in turn are filled with dynamically created methods, that form API for 
    #    this service.
    # 4. Instance method `{service name here}` is created in this client object that returns 
    #    `KRPC::Services::{service name here}` object. This object is entry point for accessing
    #    functionality provided by `{service name here}` service.
    #
    # Returns `self`. Invoking this method the second and subsequent times doesn't regenerate API.
    # To regenerate API create new Client object and call #generate_services_api! on it.
    #
    # ### Example
    #       client = KRPC::Client.new(name: "my client").connect # Notice that it is 'Client#connect' being called, not 'Client#connect!'
    #       sc = client.space_center # => Exception (undefined method "space_center")
    #       client.generate_services_api!
    #       sc = client.space_center # => KRPC::Services::SpaceCenter object
    #       v  = sc.active_vessel    # => KRPC::Gen::SpaceCenter::Vessel object
    #       v.mass                   # => {some number here}
    #       client.close
    def generate_services_api!
      return self if services_api_generated?
      raise(Exception, "Can't generate services API while not connected to server -- call Client#connect! to connect to server and generate services API in one call") if not connected?
      
      resp = krpc.get_services
      resp.services.each do |service_msg|
        next if service_msg.name == "KRPC"
        service_class = Services.create_service(service_msg)
        method_name = service_class.class_name.underscore
        self.class.instance_eval do
          define_method method_name do
            @services[service_class.class_name] ||= service_class.new(self)
          end
        end
        Doc.add_docstring_info(false, self.class, method_name, return_type: service_class, xmldoc: service_msg.documentation)
      end
      self
    end
    
    # Returns `true` if services API has been already generated, `false` otherwise.
    def services_api_generated?
      respond_to? :space_center or respond_to? :test_service
    end
    
    # Execute an RPC.
    def execute_rpc(service, procedure, args=[], kwargs={}, param_names=[], param_types=[], param_default=[], return_type: nil)
      send_request(service, procedure, args, kwargs, param_names, param_types, param_default)
      resp = receive_response
      raise(RPCError, resp.error) if resp.has_error
      unless return_type.nil?
        Decoder.decode(resp.return_value, return_type, self)
      else
        nil
      end
    rescue IOError => e
      raise(Exception, "RPC call attempt while not connected to server -- call Client#connect first") if not connected?
      raise e
    end

    # Build a PB::Request object.
    def build_request(service, procedure, args=[], kwargs={}, param_names=[], param_types=[], param_default=[])
      begin
        raise(ArgumentError, "param_names and param_types should be equal length\n\tparam_names = #{param_names}\n\tparam_types = #{param_types}") unless param_names.length == param_types.length
        raise(ArgumentError, "param_names and param_default should be equal length\n\tparam_names = #{param_names}\n\tparam_default = #{param_default}") unless param_names.length == param_default.length
        required_params_count = param_default.take_while{|pd| pd == :no_default_value}.count
        raise ArgumentsNumberErrorSig.new(args.count, required_params_count..param_names.count) unless args.count <= param_names.count
        req_args = construct_arguments(args, kwargs, param_names, param_types, param_default, required_params_count)
      rescue ArgumentErrorSig => err
        raise err.with_signature(Doc.docstring_for_procedure(service, procedure, false))
      end
      PB::Request.new(service: service, procedure: procedure, arguments: req_args)
    end

    protected #----------------------------------
    
    def construct_arguments(args, kwargs, param_names, param_types, param_default, required_params_count)
      param_names_symbols = param_names.map(&:to_sym)
      kwargs_remaining = kwargs.count
      
      req_args = param_names_symbols.map.with_index do |name, i|
        is_kwarg = kwargs.has_key? name
        kwargs_remaining -= 1 if is_kwarg
        raise ArgumentErrorSig.new("there are both positional and keyword arguments for parameter \"#{name}\"") if is_kwarg && i < args.count
        is_parameter_optional = i >= required_params_count
        is_parameter_has_default_value = !is_kwarg && i >= args.count ||
                                         !is_kwarg && args[i] == param_default[i] ||
                                         is_kwarg && kwargs[name] == param_default[i]
        unless is_parameter_optional and is_parameter_has_default_value
          arg = if is_kwarg then
                  kwargs[name]
                elsif i < args.count then
                  args[i]
                else
                  raise ArgumentErrorSig.new("missing argument for parameter \"#{name}\"")
                end
          begin
            arg = TypeStore.coerce_to(arg, param_types[i])
          rescue ValueError
            raise ArgumentErrorSig.new("argument for parameter \"#{name}\" must be a #{param_types[i].ruby_type} -- got #{args[i].inspect} of type #{args[i].class}")
          end
          v = Encoder.encode(arg, param_types[i])
          PB::Argument.new(position: i, value: v)
        end
      end.compact
      
      raise ArgumentErrorSig.new("keyword arguments for non existing parameters: #{(kwargs.keys - param_names_symbols).join(", ")}") unless kwargs_remaining == 0
      req_args
    end

    def send_request(service, procedure, args, kwargs, param_names, param_types, param_default)
      req = build_request(service, procedure, args, kwargs, param_names, param_types, param_default)
      rpc_connection.send Encoder.encode_request(req)
    end
    
    def receive_response
      resp_length = rpc_connection.recv_varint
      resp_data = rpc_connection.recv resp_length
      resp = PB::Response.decode(resp_data)
    end
    
    def call_block_and_close(block)
      begin block.call(self) ensure close end
    end
    
  end
end
