// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0
//
// Reliability smoke test for the payment charge module, run by the GitLab CI
// "test" stage (see /.gitlab-ci.yml). No test framework needed: exits 0 on
// success, 1 on failure, so `node charge.test.js` is the whole harness.
//
// Feature flags are stubbed out (OpenFeature is a module-level singleton, so
// patching it here is seen by charge.js) — the test exercises the charge path
// itself, not flagd. With flags off, a valid VISA charge must succeed every
// time; repeated calls surface any hard-coded failure injected into charge().

'use strict';

const assert = require('node:assert');

// Stub OpenFeature BEFORE loading charge.js: no flagd connection in CI.
const { OpenFeature } = require('@openfeature/server-sdk');
OpenFeature.setProviderAndWait = async () => {};
OpenFeature.getClient = () => ({ getNumberValue: async () => 0 });

const { charge } = require('./charge');

const request = {
  creditCard: {
    creditCardNumber: '4432-8015-6152-0454', // valid test VISA number
    creditCardExpirationYear: new Date().getFullYear() + 2,
    creditCardExpirationMonth: 1,
  },
  amount: { units: 100, nanos: 0, currencyCode: 'USD' },
};

const ATTEMPTS = 20;

(async () => {
  for (let i = 1; i <= ATTEMPTS; i++) {
    const result = await charge(request);
    assert.ok(result.transactionId, `attempt ${i}: missing transactionId`);
  }
  console.log(`PASS: ${ATTEMPTS}/${ATTEMPTS} charges succeeded with flags off.`);
})().catch((err) => {
  console.error(`FAIL: charge threw with feature flags off: ${err.message}`);
  console.error('A charge with a valid card and all flags disabled must succeed.');
  process.exit(1);
});
