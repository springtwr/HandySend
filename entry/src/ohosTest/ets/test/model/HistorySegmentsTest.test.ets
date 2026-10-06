import { describe, it, expect } from '@ohos/hypium'
import {
  dirtyRange,
  existingSegments,
  planSegments,
  segmentKey,
  segmentsOfDirtyRange,
  splitIntoSegments
} from '../../../../main/ets/model/HistorySegments'

/** 记录键存在性，用于驱动 existingSegments（纯函数，不依赖偏好存储）。 */
function fakeHas(existing: string[]): (key: string) => boolean {
  return (key: string): boolean => existing.indexOf(key) >= 0
}

export default function HistorySegmentsTest() {
  describe('HistorySegmentsTest', () => {
    // ── 键布局 ──

    it('segmentKey_appendsIndex', 0, () => {
      expect(segmentKey('prefix', 0)).assertEqual('prefix#0')
      expect(segmentKey('prefix', 7)).assertEqual('prefix#7')
    })

    // ── 段号探测：自 0 连续，遇缺即止 ──

    it('existingSegments_contiguousFromZero', 0, () => {
      let has = fakeHas([segmentKey('p', 0), segmentKey('p', 1), segmentKey('p', 2)])
      let found = existingSegments('p', has, 8)
      expect(found.length).assertEqual(3)
      expect(found[0]).assertEqual(0)
      expect(found[2]).assertEqual(2)
    })

    it('existingSegments_stopsAtGap', 0, () => {
      // 段号 1 缺失：其后即使存在也不计入（段号连续是写入路径的不变式）
      let has = fakeHas([segmentKey('p', 0), segmentKey('p', 2)])
      expect(existingSegments('p', has, 8).length).assertEqual(1)
    })

    it('existingSegments_emptyWhenNone', 0, () => {
      expect(existingSegments('p', fakeHas([]), 8).length).assertEqual(0)
    })

    it('existingSegments_respectsMaxSegments', 0, () => {
      let all: string[] = []
      for (let i = 0; i < 10; i++) {
        all.push(segmentKey('p', i))
      }
      expect(existingSegments('p', fakeHas(all), 4).length).assertEqual(4)
    })

    // ── 段划分：最旧段在前，末段可不足 ──

    it('splitIntoSegments_exactMultiple', 0, () => {
      let segs = splitIntoSegments<number>([1, 2, 3, 4], 2)
      expect(segs.length).assertEqual(2)
      expect(segs[0][0]).assertEqual(1)
      expect(segs[1][0]).assertEqual(3)
    })

    it('splitIntoSegments_trailingPartialSegment', 0, () => {
      let segs = splitIntoSegments<number>([1, 2, 3, 4, 5], 2)
      expect(segs.length).assertEqual(3)
      expect(segs[2].length).assertEqual(1)
      expect(segs[2][0]).assertEqual(5)
    })

    it('splitIntoSegments_emptyAndGuard', 0, () => {
      expect(splitIntoSegments<number>([], 2).length).assertEqual(0)
      expect(splitIntoSegments<number>([1, 2], 0).length).assertEqual(0)
    })

    it('splitIntoSegments_preservesOrderAndAllItems', 0, () => {
      let input: number[] = []
      for (let i = 0; i < 7; i++) {
        input.push(i)
      }
      let segs = splitIntoSegments<number>(input, 3)
      expect(segs.length).assertEqual(3)
      let flattened: number[] = []
      for (let i = 0; i < segs.length; i++) {
        for (let k = 0; k < segs[i].length; k++) {
          flattened.push(segs[i][k])
        }
      }
      expect(flattened.length).assertEqual(7)
      for (let i = 0; i < 7; i++) {
        expect(flattened[i]).assertEqual(i)
      }
    })

    // ── 裁剪计划 ──

    it('planSegments_noopUnderCapacity', 0, () => {
      let segs = planSegments<number>([1, 2, 3], 10, 2)
      expect(segs.length).assertEqual(2)
    })

    it('planSegments_trimsOldestAndKeepsNewest', 0, () => {
      // 容量 4、段大小 2：保留最近 4 条 [3,4,5,6]
      let segs = planSegments<number>([1, 2, 3, 4, 5, 6], 4, 2)
      expect(segs.length).assertEqual(2)
      expect(segs[0][0]).assertEqual(3)
      expect(segs[1][1]).assertEqual(6)
    })

    it('planSegments_capacityMultipleOfSegmentSize_dropsWholeSegments', 0, () => {
      let input: number[] = []
      for (let i = 0; i < 10; i++) {
        input.push(i)
      }
      // 容量 4 = 2 段 × 段大小 2：恰好丢弃最旧两段，无需段内裁剪
      let segs = planSegments<number>(input, 4, 2)
      expect(segs.length).assertEqual(2)
      for (let i = 0; i < segs.length; i++) {
        expect(segs[i].length).assertEqual(2)
      }
    })

    it('planSegments_emptyInput', 0, () => {
      expect(planSegments<number>([], 4, 2).length).assertEqual(0)
    })

    // ── 变更区间：追加只命中末段是分段写入成立的前提 ──

    it('dirtyRange_appendHitsOnlyTail', 0, () => {
      let range = dirtyRange([1, 2, 3], [1, 2, 3, 4, 5])
      expect(range !== undefined).assertTrue()
      expect(range?.first).assertEqual(3)
      expect(range?.last).assertEqual(4)
    })

    it('dirtyRange_appendOne', 0, () => {
      let range = dirtyRange([1, 2, 3], [1, 2, 3, 9])
      expect(range?.first).assertEqual(3)
      expect(range?.last).assertEqual(3)
    })

    it('dirtyRange_noChange_returnsUndefined', 0, () => {
      expect(dirtyRange([1, 2, 3], [1, 2, 3])).assertEqual(undefined)
    })

    it('dirtyRange_sameContentsDifferentArray_stillNoChange', 0, () => {
      // 逐项同引用即等价，无需深比较
      expect(dirtyRange([1, 2], [1, 2])).assertEqual(undefined)
    })

    it('dirtyRange_replacedMiddle', 0, () => {
      let range = dirtyRange([1, 2, 3, 4, 5], [1, 2, 9, 4, 5])
      expect(range?.first).assertEqual(2)
      expect(range?.last).assertEqual(2)
    })

    it('dirtyRange_shrinkFromFront', 0, () => {
      // 裁剪掉最旧两条
      let range = dirtyRange([1, 2, 3, 4], [3, 4])
      expect(range?.first).assertEqual(0)
      expect(range?.last).assertEqual(1)
    })

    it('dirtyRange_emptyToFull', 0, () => {
      let range = dirtyRange([], [1, 2])
      expect(range?.first).assertEqual(0)
      expect(range?.last).assertEqual(1)
    })

    it('dirtyRange_fullToEmpty_coversWholeOldRange', 0, () => {
      // 新集合为空：受影响的是旧集合整体，右端取旧集合末尾
      let range = dirtyRange([1, 2], [])
      expect(range?.first).assertEqual(0)
      expect(range?.last).assertEqual(1)
    })

    // ── 变更区间映射到段号 ──

    it('segmentsOfDirtyRange_singleSegment', 0, () => {
      let segs = segmentsOfDirtyRange({ first: 250, last: 251 }, 250)
      expect(segs.length).assertEqual(1)
      expect(segs[0]).assertEqual(1)
    })

    it('segmentsOfDirtyRange_crossesSegments', 0, () => {
      let segs = segmentsOfDirtyRange({ first: 240, last: 260 }, 250)
      expect(segs.length).assertEqual(2)
      expect(segs[0]).assertEqual(0)
      expect(segs[1]).assertEqual(1)
    })

    it('segmentsOfDirtyRange_appendMapsToLastSegmentOnly', 0, () => {
      // 段大小 250、容量 2000（8 段）：在末段追加只重写末段
      let segs = segmentsOfDirtyRange({ first: 1999, last: 1999 }, 250)
      expect(segs.length).assertEqual(1)
      expect(segs[0]).assertEqual(7)
    })

    it('segmentsOfDirtyRange_guardSegmentSize', 0, () => {
      expect(segmentsOfDirtyRange({ first: 0, last: 5 }, 0).length).assertEqual(0)
    })
  })
}
