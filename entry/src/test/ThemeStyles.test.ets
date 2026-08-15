import { describe, it, expect } from '@ohos/hypium'
import { THEME_STYLES, getThemeStyleById, getDefaultThemeStyle } from '../main/ets/utils/ThemeStyles'

export default function ThemeStylesTest() {
  describe('ThemeStylesTest', () => {
    it('getThemeStyleById_found_and_not_found', 0, () => {
      let found = getThemeStyleById('blue')
      expect(found !== null).assertTrue()
      if (found !== null) {
        expect(found.id).assertEqual('blue')
      }
      expect(getThemeStyleById('nonexistent') === null).assertTrue()
      expect(getThemeStyleById('') === null).assertTrue()
    })

    it('getDefaultThemeStyle_is_first', 0, () => {
      expect(getDefaultThemeStyle().id).assertEqual(THEME_STYLES[0].id)
    })

    it('all_ids_unique_and_nonempty', 0, () => {
      let ids: Set<string> = new Set<string>()
      for (let i = 0; i < THEME_STYLES.length; i++) {
        let style = THEME_STYLES[i]
        expect(style.id.length > 0).assertTrue()
        expect(style.label.length > 0).assertTrue()
        expect(ids.has(style.id)).assertFalse()
        ids.add(style.id)
      }
    })
  })
}
