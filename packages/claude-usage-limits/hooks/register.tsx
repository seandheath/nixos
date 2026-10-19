import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Limit } from '../types'

const limits = atom({ plugin: 'usage-limits', key: 'limits' } as const, [] as Limit[])

const BAR_WIDTH = 28

const LABELS: Record<string, string> = { five_hour: '5h', seven_day: '7d', spend_limit: 'spend' }

function untilReset(resetsAt: string, now: number): string {
  const minutes = Math.max(0, Math.round((Date.parse(resetsAt) - now) / 60000))
  if (minutes < 60) return `${minutes}m`
  if (minutes < 48 * 60) return `${Math.floor(minutes / 60)}h${minutes % 60}m`
  return `${Math.floor(minutes / 1440)}d${Math.floor((minutes % 1440) / 60)}h`
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const { rateLimits } = await $.session.usage()
    await update($, limits, () => rateLimits)
    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    await update($, limits, () => e.rateLimits)
    return next(e)
  })

  on('ui.render', { component: 'PromptHint' }, async ($, e, next) => {
    const current = await read($, limits)
    if (current.length === 0) return next(e)

    const now = await $.clock.now()
    const { Box, Text } = $.ui.resolve(e)

    return (
      <Box flexDirection="column">
        {await next(e)}
        <Box flexWrap="wrap" columnGap={1}>
          {current.map(limit => {
            const reset = limit.resetsAt ? ` · ${untilReset(limit.resetsAt, now)}` : ''
            const label = `${LABELS[limit.kind] ?? limit.kind} ${limit.percentUsed}%${reset}`
            const pad = Math.max(0, BAR_WIDTH - label.length)
            const text = (' '.repeat(Math.floor(pad / 2)) + label).padEnd(BAR_WIDTH)
            const filled = Math.round((Math.min(limit.percentUsed, 100) / 100) * BAR_WIDTH)
            const color = limit.percentUsed >= 90 ? 'error' : limit.percentUsed >= 70 ? 'warning' : 'success'
            return (
              <Text>
                <Text color="black" backgroundColor={color}>{text.slice(0, filled)}</Text>
                <Text color="black" backgroundColor="inactive">{text.slice(filled)}</Text>
              </Text>
            )
          })}
        </Box>
      </Box>
    )
  })
}
