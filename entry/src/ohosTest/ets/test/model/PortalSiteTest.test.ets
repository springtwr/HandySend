import { describe, it, expect } from '@ohos/hypium'
import {
  mergePortalSites,
  normalizePortalUrl,
  parseDismissedIds,
  parsePortalSiteConfig,
  PortalSite,
  PORTAL_BADGE_LARGE_FILE,
  PORTAL_BADGE_LOGIN,
  PORTAL_BADGE_NO_LOGIN,
  samePortalSites,
  sanitizePortalName
} from '../../../../main/ets/model/PortalSite'

/** 构造测试站点。 */
function site(id: string, name: string, url: string, builtin: boolean, order: number,
  badges: Array<string> = []): PortalSite {
  return {
    id: id,
    name: name,
    url: url,
    badges: badges,
    builtin: builtin,
    order: order
  }
}

export default function PortalSiteTest() {
  describe('PortalSiteTest', () => {
    // ── 地址校验 ──

    it('normalizePortalUrl_accepts_https_and_http', 0, () => {
      expect(normalizePortalUrl('https://upfile.live/zh-cn'))
        .assertEqual('https://upfile.live/zh-cn')
      expect(normalizePortalUrl('  http://example.com/a?b=1  '))
        .assertEqual('http://example.com/a?b=1')
    })

    it('normalizePortalUrl_rejects_unsafe_or_empty', 0, () => {
      expect(normalizePortalUrl('')).assertEqual('')
      expect(normalizePortalUrl('javascript:alert(1)')).assertEqual('')
      expect(normalizePortalUrl('data:text/html,hi')).assertEqual('')
      expect(normalizePortalUrl('example.com')).assertEqual('')
      expect(normalizePortalUrl('https://exa mple.com')).assertEqual('')
      expect(normalizePortalUrl('https://user:pass@example.com')).assertEqual('')
      expect(normalizePortalUrl('https://')).assertEqual('')
    })

    // ── 名称清洗 ──

    it('sanitizePortalName_trims_and_limits', 0, () => {
      expect(sanitizePortalName('  UpFile  ')).assertEqual('UpFile')
      expect(sanitizePortalName('a\u0000b')).assertEqual('ab')
      expect(sanitizePortalName('x'.repeat(60)).length).assertEqual(40)
    })

    // ── 配置解析 ──

    it('parsePortalSiteConfig_reads_sites', 0, () => {
      let text: string = '{"schemaVersion":1,"sites":[' +
        '{"id":"a","name":"A","url":"https://a.com","badges":["no-login","large-file"],"order":10},' +
        '{"id":"b","name":"B","url":"https://b.com","badges":["login"],"order":20}]}'
      let config = parsePortalSiteConfig(text)
      expect(config === undefined).assertFalse()
      if (config !== undefined) {
        expect(config.sites.length).assertEqual(2)
        expect(config.sites[0].builtin).assertTrue()
        expect(config.sites[0].badges.length).assertEqual(2)
        expect(config.sites[1].badges[0]).assertEqual(PORTAL_BADGE_LOGIN)
      }
    })

    it('parsePortalSiteConfig_rejects_bad_version_or_json', 0, () => {
      expect(parsePortalSiteConfig('not json') === undefined).assertTrue()
      expect(parsePortalSiteConfig(JSON.stringify({ schemaVersion: 9, sites: [] })) === undefined)
        .assertTrue()
    })

    it('parsePortalSiteConfig_skips_invalid_and_duplicate', 0, () => {
      let text: string = '{"schemaVersion":1,"sites":[' +
        '{"id":"a","name":"A","url":"javascript:alert(1)"},' +
        '{"id":"b","name":"B","url":"https://b.com"},' +
        '{"id":"b","name":"B2","url":"https://b2.com"},' +
        '{"id":"","name":"C","url":"https://c.com"},' +
        '{"id":"d","name":"","url":"https://d.com"}]}'
      let config = parsePortalSiteConfig(text)
      expect(config === undefined).assertFalse()
      if (config !== undefined) {
        expect(config.sites.length).assertEqual(1)
        expect(config.sites[0].id).assertEqual('b')
      }
    })

    it('parsePortalSiteConfig_filters_unknown_badges', 0, () => {
      let text: string = '{"schemaVersion":1,"sites":[' +
        '{"id":"a","name":"A","url":"https://a.com","badges":["no-login","evil","large-file"]}]}'
      let config = parsePortalSiteConfig(text)
      if (config !== undefined) {
        expect(config.sites[0].badges.length).assertEqual(2)
        expect(config.sites[0].badges[0]).assertEqual(PORTAL_BADGE_NO_LOGIN)
        expect(config.sites[0].badges[1]).assertEqual(PORTAL_BADGE_LARGE_FILE)
      }
    })

    // ── 合并与删除记录 ──

    it('mergePortalSites_keeps_user_sites_and_excludes_dismissed', 0, () => {
      let presets: Array<PortalSite> = [
        site('a', 'A', 'https://a.com', true, 10),
        site('b', 'B', 'https://b.com', true, 20)
      ]
      let local: Array<PortalSite> = [
        site('u1', 'U1', 'https://u1.com', false, 30)
      ]
      let merged = mergePortalSites(local, presets, ['a'])
      expect(merged.length).assertEqual(2)
      expect(merged[0].id).assertEqual('b')
      expect(merged[1].id).assertEqual('u1')
    })

    it('mergePortalSites_sorts_by_order', 0, () => {
      let presets: Array<PortalSite> = [
        site('b', 'B', 'https://b.com', true, 20),
        site('a', 'A', 'https://a.com', true, 10)
      ]
      let merged = mergePortalSites([], presets, [])
      expect(merged[0].id).assertEqual('a')
      expect(merged[1].id).assertEqual('b')
    })

    it('parseDismissedIds_dedups', 0, () => {
      let ids = parseDismissedIds('a,b, a ,,b')
      expect(ids.length).assertEqual(2)
      expect(ids[0]).assertEqual('a')
      expect(ids[1]).assertEqual('b')
    })

    // ── 等价判定 ──

    it('samePortalSites_compares_fields', 0, () => {
      let a: Array<PortalSite> = [site('a', 'A', 'https://a.com', true, 10, [PORTAL_BADGE_NO_LOGIN])]
      let b: Array<PortalSite> = [site('a', 'A', 'https://a.com', true, 10, [PORTAL_BADGE_NO_LOGIN])]
      let c: Array<PortalSite> = [site('a', 'A', 'https://a.com', true, 10, [PORTAL_BADGE_LOGIN])]
      expect(samePortalSites(a, b)).assertTrue()
      expect(samePortalSites(a, c)).assertFalse()
    })
  })
}
