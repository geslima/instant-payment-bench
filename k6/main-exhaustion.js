import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';
import { uuidv4 } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:5000';

function getHotAccountIds() {
  const ids = [];
  const envKeys = Object.keys(__ENV).filter(k => k.startsWith('HOT_ACCOUNT_'));
  for (const key of envKeys) {
    ids.push(parseInt(__ENV[key], 10));
  }
  return ids;
}

const HOT_ACCOUNTS = getHotAccountIds();

if (HOT_ACCOUNTS.length === 0) {
  console.error('ERROR: No hot accounts found in environment variables.');
}

const headers = { 'Content-Type': 'application/json' };

const serverOverloaded = new Counter('server_overloaded_503');
const transferErrors = new Counter('transfer_errors');
const transfersCommitted = new Counter('transfers_committed');
const transfersRejected = new Counter('transfers_rejected');
const transferDuration = new Trend('transfer_duration', true);
const deadlockRetries = new Counter('deadlock_retries');
const HOT_ACCOUNTS_MODE = __ENV.HOT_ACCOUNTS_MODE || 'x10';

function getRandomAccountId() {
  return Math.floor(Math.random() * 100000) + 1;
}

function getHotAccountId() {
  if (HOT_ACCOUNTS_MODE === 'x1') {
    return HOT_ACCOUNTS[0];
  }
  return HOT_ACCOUNTS[Math.floor(Math.random() * HOT_ACCOUNTS.length)];
}

function isExpected(status) {
  return status === 200 || status === 503;
}

const SCALE = parseInt(__ENV.VU_SCALE || '1');

export const options = {
  scenarios: {
    commit_transfer: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '10s', target: 110 * SCALE },
        { duration: '5m', target: 110 * SCALE },
        { duration: '10s', target: 0 },
      ],
      exec: 'commitTransfer',
    },
    browse_balance: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '10s', target: 300 * SCALE },
        { duration: '5m', target: 300 * SCALE },
        { duration: '10s', target: 0 },
      ],
      exec: 'browseBalance',
    },
    idempotency_replay: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '10s', target: 90 * SCALE },
        { duration: '5m', target: 90 * SCALE },
        { duration: '10s', target: 0 },
      ],
      exec: 'idempotencyReplay',
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<5000'],
    http_req_failed: ['rate<0.01'],
    transfer_errors: ['count<200'],
  },
};

export function commitTransfer() {
  const fromAccount = getHotAccountId();
  const toAccount = getRandomAccountId();
  const idempotencyKey = uuidv4();

  const payload = JSON.stringify({
    fromAccountId: fromAccount,
    toAccountId: toAccount,
    amountCents: 100,
    idempotencyKey: idempotencyKey
  });

  const reqOpts = { headers, tags: { name: 'commit_transfer', url: '/api/transfers/commit' } };

  let res;
  for (let attempt = 0; attempt <= 3; attempt++) {
    if (attempt > 0) {
      sleep(Math.random() * 0.08 + 0.02);
    }

    res = http.post(`${BASE_URL}/api/transfers/commit`, payload, reqOpts);
    transferDuration.add(res.timings.duration);

    if (res.status === 200) {
      const data = res.json();
      if (data.status === 2) transfersCommitted.add(1);
      else if (data.status === 3) transfersRejected.add(1);
      break;
    } else if (res.status === 503) {
      const isDeadlock = (res.body && res.body.includes('deadlock'));
      if (isDeadlock && attempt < 3) {
        deadlockRetries.add(1);
        continue;
      }
      serverOverloaded.add(1);
      break;
    } else {
      transferErrors.add(1);
      break;
    }
  }

  check(res, {
    'commit_transfer - ok': (r) => isExpected(r.status),
  });

  sleep(Math.random() * 2 + 0.5);
}

export function browseBalances() {
  browseBalance();
}

export function browseBalance() {
  const accountId = getRandomAccountId();
  const reqOpts = { tags: { name: 'browse_balance', url: '/api/accounts/:id/balance' } };
  const res = http.get(`${BASE_URL}/api/accounts/${accountId}/balance`, reqOpts);
  check(res, {
    'browse_balance - ok': (r) => isExpected(r.status),
  });
  if (res.status === 503) serverOverloaded.add(1);
  sleep(Math.random() * 3 + 1);
}

let savedKey = null;

export function idempotentReplay() {
  idempotencyReplay();
}

export function idempotencyReplay() {
  const idempotencyKey = savedKey ? savedKey : uuidv4();

  const fromAccount = getHotAccountId();
  const toAccount = getRandomAccountId();

  const payload = JSON.stringify({
    fromAccountId: fromAccount,
    toAccountId: toAccount,
    amountCents: 100,
    idempotencyKey: idempotencyKey
  });

  const reqOpts = { headers, tags: { name: 'idempotency_replay', url: '/api/transfers/commit' } };

  let res;
  for (let attempt = 0; attempt <= 3; attempt++) {
    if (attempt > 0) {
      sleep(Math.random() * 0.08 + 0.02);
    }

    res = http.post(`${BASE_URL}/api/transfers/commit`, payload, reqOpts);
    transferDuration.add(res.timings.duration);

    if (res.status === 200) {
      const data = res.json();
      if (data.status === 2) transfersCommitted.add(1);
      else if (data.status === 3) transfersRejected.add(1);
      break;
    } else if (res.status === 503) {
      const isDeadlock = (res.body && res.body.includes('deadlock'));
      if (isDeadlock && attempt < 3) {
        deadlockRetries.add(1);
        continue;
      }
      serverOverloaded.add(1);
      break;
    } else {
      transferErrors.add(1);
      break;
    }
  }

  check(res, {
    'idempotency_replay - ok': (r) => isExpected(r.status),
  });

  savedKey = idempotencyKey;

  sleep(Math.random() * 2 + 1);
}

