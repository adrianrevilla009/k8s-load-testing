// One script, several load shapes. Pick with SCENARIO=baseline|ramp|spike.
// k6-operator mounts a single file, so everything lives here.
import http from 'k6/http';
import { check } from 'k6';

const ENTRYPOINTS = (__ENV.ENTRYPOINTS || 'fe-001').split(',');
const NAMESPACE = __ENV.NAMESPACE || 'mesh';
const SCENARIO = __ENV.SCENARIO || 'baseline';
const RATE = parseInt(__ENV.RATE || '20', 10); // user requests per second

const shapes = {
  // steady traffic: best for watching a canary step or an A/B split settle
  baseline: {
    executor: 'constant-arrival-rate',
    rate: RATE,
    timeUnit: '1s',
    duration: '30m',
    preAllocatedVUs: 20,
    maxVUs: 200,
  },
  // up and down: shows autoscaling-free behaviour under growing load
  ramp: {
    executor: 'ramping-arrival-rate',
    startRate: Math.max(1, Math.floor(RATE / 4)),
    timeUnit: '1s',
    preAllocatedVUs: 20,
    maxVUs: 300,
    stages: [
      { target: RATE, duration: '2m' },
      { target: RATE * 2, duration: '3m' },
      { target: RATE, duration: '2m' },
    ],
  },
  // sudden burst: shows latency / error cascades through the tiers
  spike: {
    executor: 'ramping-arrival-rate',
    startRate: RATE,
    timeUnit: '1s',
    preAllocatedVUs: 50,
    maxVUs: 400,
    stages: [
      { target: RATE, duration: '2m' },
      { target: RATE * 5, duration: '20s' },
      { target: RATE * 5, duration: '1m' },
      { target: RATE, duration: '20s' },
      { target: RATE, duration: '2m' },
    ],
  },
};

export const options = {
  scenarios: { [SCENARIO]: shapes[SCENARIO] },
};

export default function () {
  const entry = ENTRYPOINTS[Math.floor(Math.random() * ENTRYPOINTS.length)];

  // 1000 stable pseudo-users; every 5th one is in the "beta" group (20%).
  // fake-service forwards request headers upstream, so the A/B VirtualService
  // deep in the graph still sees x-user-group.
  const uid = Math.floor(Math.random() * 1000);
  const group = uid % 5 === 0 ? 'beta' : 'control';

  const res = http.get(`http://${entry}.${NAMESPACE}.svc.cluster.local:9090/`, {
    headers: { 'x-user-id': String(uid), 'x-user-group': group },
    tags: { group },
  });
  check(res, { 'status is 200': (r) => r.status === 200 });
}
