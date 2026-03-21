# frozen_string_literal: true

require "json"

module X402
  # RFC 8785 canonical JSON serialisation.
  # Sorted keys, no whitespace, integers without trailing decimals.
  # Sufficient for ASCII-only keys used in x402 v1.
  module CanonicalJson
    module_function

    def encode(obj)
      canonicalise(obj)
    end

    private_class_method def self.canonicalise(value)
      case value
      when Hash
        pairs = value.sort_by { |k, _| k.to_s }.map do |k, v|
          "#{canonicalise(k.to_s)}:#{canonicalise(v)}"
        end
        "{#{pairs.join(",")}}"
      when Array
        "[#{value.map { |v| canonicalise(v) }.join(",")}]"
      when String
        JSON.generate(value)
      when Integer
        value.to_s
      when Float
        # RFC 8785: integers without decimal point
        value == value.to_i ? value.to_i.to_s : JSON.generate(value)
      when true then "true"
      when false then "false"
      when nil then "null"
      end
    end
  end
end
