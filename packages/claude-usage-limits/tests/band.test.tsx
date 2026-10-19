import { expect, mock, test } from 'claude-code/testing'

const HINT = {
  component: 'PromptHint',
  props: { isDraft: false, isWorking: false, hint: '? for shortcuts' },
} as const

test('each window draws as a bar with its label inside, under the engine hint', async ($, on) => {
  mock.clock(on, { now: Date.parse('2026-10-19T12:00:00Z') })
  on('session.measure', ($, e) => ({ changed: e.changed }))
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>? for shortcuts</Text>
  })

  await $.session.measure({
    context: { window: 200000 },
    rateLimits: [
      { kind: 'five_hour', percentUsed: 25, resetsAt: '2026-10-19T13:30:00Z' },
      { kind: 'seven_day', percentUsed: 91 },
    ],
    changed: ['rateLimits'],
  })

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ plugin: 'usage-limits', surface, ...HINT })
    expect(await ui.find({ type: 'Text', text: '? for shortcuts' })).toBeDefined()
    // 25% of 28 cells is 7 filled: the label "5h 25% · 1h30m" starts at cell 7.
    expect(await ui.find({ type: 'Text', text: /^ {7}$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: '5h 25% · 1h30m' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: '7d 91%' })).toBeDefined()
    await ui.unmount()
  }
})

test('only the engine hint shows before any reading', async ($, on) => {
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>? for shortcuts</Text>
  })

  const ui = await $.ui.mount({ plugin: 'usage-limits', surface: 'terminal', ...HINT })
  expect(await ui.find({ type: 'Text', text: '5h' })).toBeUndefined()
  await ui.unmount()
})
