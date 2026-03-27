# frozen_string_literal: true

require "rack"
require_relative "../../../lib/x402/protocol/request_binding"

RSpec.describe X402::RequestBinding do
  def mock_request(body: "", headers: {})
    env = Rack::MockRequest.env_for("/test", method: "GET", input: body)
    headers.each { |k, v| env["HTTP_#{k.upcase.tr("-", "_")}"] = v }
    Rack::Request.new(env)
  end

  describe ".body_sha256" do
    it "returns SHA-256 hex of request body" do
      request = mock_request(body: "hello")
      expected = OpenSSL::Digest::SHA256.hexdigest("hello")
      expect(described_class.body_sha256(request)).to eq(expected)
    end

    it "returns hash of empty string when body is empty" do
      request = mock_request(body: "")
      expected = OpenSSL::Digest::SHA256.hexdigest("")
      expect(described_class.body_sha256(request)).to eq(expected)
    end
  end

  describe ".headers_sha256" do
    it "returns hash of empty string for v1" do
      request = mock_request
      expected = OpenSSL::Digest::SHA256.hexdigest("")
      expect(described_class.headers_sha256(request)).to eq(expected)
    end
  end
end
