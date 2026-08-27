import { describe, it, expect } from '@ohos/hypium'
import {
  WidthBreakpointType, getMaxContentWidth, isNarrowWidth
} from '../main/ets/common/Breakpoints'

// 断点工具模块的纯逻辑单测（无 UIContext/系统依赖）。
export default function BreakpointsTest() {
  describe('BreakpointsTest', () => {
    // ── WidthBreakpointType.getValue 断点映射 ──

    it('getValue_xs_uses_sm', 0, () => {
      let bp: WidthBreakpointType<string> = new WidthBreakpointType<string>('sm', 'md', 'lg', 'xl')
      expect(bp.getValue(WidthBreakpoint.WIDTH_XS)).assertEqual('sm')
    })

    it('getValue_sm_uses_sm', 0, () => {
      let bp: WidthBreakpointType<string> = new WidthBreakpointType<string>('sm', 'md', 'lg', 'xl')
      expect(bp.getValue(WidthBreakpoint.WIDTH_SM)).assertEqual('sm')
    })

    it('getValue_md_uses_md', 0, () => {
      let bp: WidthBreakpointType<string> = new WidthBreakpointType<string>('sm', 'md', 'lg', 'xl')
      expect(bp.getValue(WidthBreakpoint.WIDTH_MD)).assertEqual('md')
    })

    it('getValue_lg_uses_lg', 0, () => {
      let bp: WidthBreakpointType<string> = new WidthBreakpointType<string>('sm', 'md', 'lg', 'xl')
      expect(bp.getValue(WidthBreakpoint.WIDTH_LG)).assertEqual('lg')
    })

    it('getValue_xl_uses_xl', 0, () => {
      let bp: WidthBreakpointType<string> = new WidthBreakpointType<string>('sm', 'md', 'lg', 'xl')
      expect(bp.getValue(WidthBreakpoint.WIDTH_XL)).assertEqual('xl')
    })

    // ── getMaxContentWidth 各断点取值 ──

    it('maxContentWidth_xs_zero', 0, () => {
      expect(getMaxContentWidth(WidthBreakpoint.WIDTH_XS)).assertEqual(0)
    })

    it('maxContentWidth_sm_zero', 0, () => {
      expect(getMaxContentWidth(WidthBreakpoint.WIDTH_SM)).assertEqual(0)
    })

    it('maxContentWidth_md_800', 0, () => {
      expect(getMaxContentWidth(WidthBreakpoint.WIDTH_MD)).assertEqual(800)
    })

    it('maxContentWidth_lg_960', 0, () => {
      expect(getMaxContentWidth(WidthBreakpoint.WIDTH_LG)).assertEqual(960)
    })

    it('maxContentWidth_xl_1120', 0, () => {
      expect(getMaxContentWidth(WidthBreakpoint.WIDTH_XL)).assertEqual(1120)
    })

    // ── isNarrowWidth 边界 ──

    it('isNarrowWidth_xs_true', 0, () => {
      expect(isNarrowWidth(WidthBreakpoint.WIDTH_XS)).assertTrue()
    })

    it('isNarrowWidth_sm_true', 0, () => {
      expect(isNarrowWidth(WidthBreakpoint.WIDTH_SM)).assertTrue()
    })

    it('isNarrowWidth_md_false', 0, () => {
      expect(isNarrowWidth(WidthBreakpoint.WIDTH_MD)).assertFalse()
    })

    it('isNarrowWidth_lg_false', 0, () => {
      expect(isNarrowWidth(WidthBreakpoint.WIDTH_LG)).assertFalse()
    })

    it('isNarrowWidth_xl_false', 0, () => {
      expect(isNarrowWidth(WidthBreakpoint.WIDTH_XL)).assertFalse()
    })
  })
}
