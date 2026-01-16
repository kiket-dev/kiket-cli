import { handleEvent } from '../src/handler';

test('before transition allows by default', async () => {
  const response = await handleEvent({ event_type: 'before_transition' } as any);
  expect(response.status).toBeDefined();
});
