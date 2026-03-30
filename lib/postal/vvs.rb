module Postal
  module VVS
    autoload :Canonicalizer, 'postal/vvs/canonicalizer'
    autoload :Signer, 'postal/vvs/signer'
    autoload :Verifier, 'postal/vvs/verifier'
    autoload :KeyResolver, 'postal/vvs/key_resolver'
    autoload :NonceCache, 'postal/vvs/nonce_cache'
  end
end
