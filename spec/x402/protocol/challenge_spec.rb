# frozen_string_literal: true

# These specs test X402::Challenge which is being migrated into X402::BSV::ProofGateway
# as part of the BSV gateway implementation (issue #5). The Challenge class depends on
# Configuration#nonce_provider which was removed in the middleware dispatcher refactor.
# These tests are preserved here as documentation of the expected behaviour and will be
# reinstated under the BSV gateway spec once that module is built.

RSpec.describe "X402::Challenge" do
  pending "migrating to X402::BSV::ProofGateway — see issue #5"
end
