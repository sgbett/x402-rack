# frozen_string_literal: true

module X402
  # Returned by Gateway#settle! on successful settlement.
  #
  # @attr receipt_headers [Hash] HTTP headers to include in the 200 response
  # @attr txid [String, nil] transaction identifier
  # @attr network [String, nil] CAIP-2 network identifier (e.g. "bsv:mainnet")
  SettlementResult = Struct.new(:receipt_headers, :txid, :network, keyword_init: true) do
    def initialize(receipt_headers: {}, txid: nil, network: nil)
      super
    end
  end
end
