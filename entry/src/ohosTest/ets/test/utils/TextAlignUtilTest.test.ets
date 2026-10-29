import { describe, it, expect } from '@ohos/hypium'
import { hasExplicitLineBreak } from '../../../../main/ets/utils/TextAlignUtil'

export default function TextAlignUtilTest() {
  describe('TextAlignUtilTest', () => {
    it('hasExplicitLineBreak_detectsAllLineSeparators', 0, () => {
      // 单行文本：交给测量宽度判定居中/左对齐
      expect(hasExplicitLineBreak('单行短文本')).assertFalse()
      // 多行短文本：即使测量宽度小于内容区宽度，也必须按多行左对齐
      expect(hasExplicitLineBreak('第一行\n第二行')).assertTrue()
      expect(hasExplicitLineBreak('第一行\r\n第二行')).assertTrue()
      expect(hasExplicitLineBreak('第一行\u2028第二行')).assertTrue()
      expect(hasExplicitLineBreak('第一行\u2029第二行')).assertTrue()
      // 空串按单行处理（由可用宽度分支兜底）
      expect(hasExplicitLineBreak('')).assertFalse()
    })
  })
}
