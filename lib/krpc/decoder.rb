require 'krpc/protobuf_utils'
require 'set'

module KRPC
  module Decoder
    OK_LENGTH = 2
    OK_MESSAGE = "\x4F\x4B"
    GUID_LENGTH = 16
    
    class << self
    
      # Given a type object, and serialized data, decode the ruby value/object
      def decode(data, type, client)
        if type.is_a?(Types::MessageType) then decode_message(data, type)
        elsif type.is_a?(Types::ValueType) then decode_value(data, type)
        elsif type.is_a?(Types::EnumType) 
          v = decode_value(data, TypeStore["int32"])
          type.ruby_type.key(v)
        elsif type.is_a?(Types::ClassType)
          remote_oid = decode_value(data, TypeStore["uint64"])
          if remote_oid != 0
            type.ruby_type.new(client, remote_oid)
          else nil end
        elsif type.is_a?(Types::ListType)
          msg = decode_message(data, TypeStore["KRPC.List"])
          msg.items.map{|x| decode(x, type.value_type, client)}.to_a
        elsif type.is_a?(Types::DictionaryType)
          msg = decode_message(data, TypeStore["KRPC.Dictionary"])
          msg.entries.map{|e| [decode(e.key,   type.key_type,   client),
                               decode(e.value, type.value_type, client)]}.to_h
        elsif type.is_a?(Types::SetType)
          msg = decode_message(data, TypeStore["KRPC.Set"])
          Set.new(msg.items.map{|x| decode(x, type.value_type, client)}.to_a)
        elsif type.is_a?(Types::TupleType)
          msg = decode_message(data, TypeStore["KRPC.Tuple"])
          msg.items.zip(type.value_types).map{|x,t| decode(x, t, client)}.to_a
        else raise RuntimeError.new("Cannot decode type #{type} from data: #{data}")
        end
      end

      def decode_value(data, type)
        ProtobufUtils::Decoder.decode(data, type.protobuf_type)
      end
      
      def decode_message(data, type)
        type.ruby_type.decode(data.to_s)
      end
      
    end
  end
end
