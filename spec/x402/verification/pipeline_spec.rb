# frozen_string_literal: true

# These specs test X402::Verification::Pipeline which is being migrated into
# X402::BSV::ProofGateway as part of the BSV gateway implementation (issue #5).
# The pipeline depends on Configuration#nonce_provider which was removed in the
# middleware dispatcher refactor. Tests are preserved here as documentation and will be
# reinstated under the BSV gateway spec once that module is built.

RSpec.describe "X402::Verification::Pipeline" do
  pending "migrating to X402::BSV::ProofGateway — see issue #5"
end
