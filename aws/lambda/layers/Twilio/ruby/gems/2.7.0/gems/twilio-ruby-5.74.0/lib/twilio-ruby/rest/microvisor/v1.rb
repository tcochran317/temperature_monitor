##
# This code was generated by
# \ / _    _  _|   _  _
#  | (_)\/(_)(_|\/| |(/_  v1.0.0
#       /       /
#
# frozen_string_literal: true

module Twilio
  module REST
    class Microvisor
      class V1 < Version
        ##
        # Initialize the V1 version of Microvisor
        def initialize(domain)
          super
          @version = 'v1'
          @apps = nil
          @devices = nil
        end

        ##
        # @param [String] sid A 34-character string that uniquely identifies this App.
        # @return [Twilio::REST::Microvisor::V1::AppContext] if sid was passed.
        # @return [Twilio::REST::Microvisor::V1::AppList]
        def apps(sid=:unset)
          if sid.nil?
              raise ArgumentError, 'sid cannot be nil'
          end
          if sid == :unset
              @apps ||= AppList.new self
          else
              AppContext.new(self, sid)
          end
        end

        ##
        # @param [String] sid A 34-character string that uniquely identifies this Device.
        # @return [Twilio::REST::Microvisor::V1::DeviceContext] if sid was passed.
        # @return [Twilio::REST::Microvisor::V1::DeviceList]
        def devices(sid=:unset)
          if sid.nil?
              raise ArgumentError, 'sid cannot be nil'
          end
          if sid == :unset
              @devices ||= DeviceList.new self
          else
              DeviceContext.new(self, sid)
          end
        end

        ##
        # Provide a user friendly representation
        def to_s
          '<Twilio::REST::Microvisor::V1>'
        end
      end
    end
  end
end