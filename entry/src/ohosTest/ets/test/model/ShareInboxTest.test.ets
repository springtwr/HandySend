import { describe, it, expect } from '@ohos/hypium'
import {
  mergeShareTextJson,
  mergeShareUriJson,
  parseShareUriList,
  SHARE_MAX_ITEMS,
  SHARE_MAX_TEXTS
} from '../../../../main/ets/model/ShareInbox'

function uriList(count: number, prefix: string): string {
  let list: Array<string> = []
  for (let i = 0; i < count; i++) {
    list.push('file://' + prefix + i)
  }
  return JSON.stringify(list)
}

function textList(count: number, prefix: string): string {
  let list: Array<Record<string, string>> = []
  for (let i = 0; i < count; i++) {
    let record: Record<string, string> = {
      'content': prefix + i,
      'title': '',
      'utd': 'general.text'
    }
    list.push(record)
  }
  return JSON.stringify(list)
}

export default function ShareInboxTest() {
  describe('ShareInboxTest', () => {
    it('parse_uri_rejects_invalid_json', 0, () => {
      expect(parseShareUriList('').length).assertEqual(0)
      expect(parseShareUriList('{}').length).assertEqual(0)
      expect(parseShareUriList('not-json').length).assertEqual(0)
      expect(parseShareUriList('["a", 1, "b"]').length).assertEqual(2)
    })

    it('merge_uris_dedupes', 0, () => {
      let first: string = uriList(3, 'a')
      let second: string = uriList(3, 'a')
      let result = mergeShareUriJson(first, second)
      expect(parseShareUriList(result.json).length).assertEqual(3)
      expect(result.truncatedCount).assertEqual(0)
    })

    it('merge_uris_truncates_to_limit', 0, () => {
      let first: string = uriList(SHARE_MAX_ITEMS, 'a')
      let second: string = uriList(100, 'b')
      let result = mergeShareUriJson(first, second)
      expect(parseShareUriList(result.json).length).assertEqual(SHARE_MAX_ITEMS)
      expect(result.truncatedCount).assertEqual(100)
    })

    it('merge_texts_respects_count_limit', 0, () => {
      let result = mergeShareTextJson(textList(SHARE_MAX_TEXTS, 'a'), textList(5, 'b'))
      let parsed: Array<Object> = JSON.parse(result.json) as Array<Object>
      expect(parsed.length).assertEqual(SHARE_MAX_TEXTS)
      expect(result.truncatedCount).assertEqual(5)
    })

    it('merge_texts_keeps_at_least_one_when_over_chars', 0, () => {
      let longText: string = 'x'.repeat(250000)
      let json: string = JSON.stringify([{ 'content': longText, 'title': '', 'utd': 'general.text' }])
      let result = mergeShareTextJson('', json)
      let parsed: Array<Object> = JSON.parse(result.json) as Array<Object>
      expect(parsed.length).assertEqual(1)
    })
  })
}
