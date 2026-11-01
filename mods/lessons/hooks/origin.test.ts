import { expect, test } from 'claude-code/testing'

import { countsAsMine } from './register'

// The failure count reads only the person's main loop (walk-tasks PLAN step 6).
test('a failed call counts only from the main loop and the engine', () => {
  expect(countsAsMine(undefined, 'engine', true)).toBe(true)
  expect(countsAsMine(undefined, undefined, true)).toBe(true)
  expect(countsAsMine(undefined, 'walk', true)).toBe(false) // the walk mod's TaskUpdate
  expect(countsAsMine(undefined, 'lessons', true)).toBe(false)
  expect(countsAsMine('sub-1', 'engine', true)).toBe(false)
  expect(countsAsMine(undefined, 'engine', false)).toBe(false)
  expect(countsAsMine(undefined, 'engine', undefined)).toBe(false)
})
