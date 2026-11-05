import Testing

@testable import TobiCore

@Suite("イベントタップの timeout の連続の判定（design.md 7.4）")
struct TapTimeoutBreakerTests {
    private static func seconds(_ value: UInt64, plusNanoseconds extra: UInt64 = 0) -> Timestamp {
        Timestamp(nanoseconds: value * 1_000_000_000 + extra)
    }

    @Test("閾値と窓: 30 秒以内に 3 回")
    func constants() {
        #expect(TapTimeoutBreaker.abandonThreshold == 3)
        #expect(TapTimeoutBreaker.windowSeconds == 30)
    }

    @Test("2 回では異常にならない")
    func twoTimeoutsRecover() {
        var breaker = TapTimeoutBreaker()

        #expect(breaker.recordTimeout(at: Self.seconds(100)) == .recover)
        #expect(breaker.recordTimeout(at: Self.seconds(101)) == .recover)
    }

    @Test("30 秒以内の 3 回で異常になる")
    func threeTimeoutsWithinWindowAbandon() {
        var breaker = TapTimeoutBreaker()

        #expect(breaker.recordTimeout(at: Self.seconds(100)) == .recover)
        #expect(breaker.recordTimeout(at: Self.seconds(110)) == .recover)
        #expect(breaker.recordTimeout(at: Self.seconds(120)) == .abandon)
    }

    @Test("実機の不具合の間隔（01:26:48・01:26:55・01:27:09）で 3 回目に異常になる")
    func incidentIntervals() {
        var breaker = TapTimeoutBreaker()

        #expect(breaker.recordTimeout(at: Self.seconds(1000)) == .recover)
        #expect(breaker.recordTimeout(at: Self.seconds(1007)) == .recover)
        #expect(breaker.recordTimeout(at: Self.seconds(1021)) == .abandon)
    }

    @Test("同じ時刻の 3 回でも異常になる")
    func sameTimestamp() {
        var breaker = TapTimeoutBreaker()

        #expect(breaker.recordTimeout(at: Self.seconds(100)) == .recover)
        #expect(breaker.recordTimeout(at: Self.seconds(100)) == .recover)
        #expect(breaker.recordTimeout(at: Self.seconds(100)) == .abandon)
    }

    @Test("境界: 1 回目からちょうど 30 秒の 3 回目は窓の中")
    func exactlyAtWindowBoundary() {
        var breaker = TapTimeoutBreaker()

        #expect(breaker.recordTimeout(at: Self.seconds(100)) == .recover)
        #expect(breaker.recordTimeout(at: Self.seconds(115)) == .recover)
        #expect(breaker.recordTimeout(at: Self.seconds(130)) == .abandon)
    }

    @Test("境界: 1 回目から 30 秒と 1 ナノ秒の 3 回目は窓の外")
    func justOutsideWindowBoundary() {
        var breaker = TapTimeoutBreaker()

        #expect(breaker.recordTimeout(at: Self.seconds(100)) == .recover)
        #expect(breaker.recordTimeout(at: Self.seconds(115)) == .recover)
        #expect(breaker.recordTimeout(at: Self.seconds(130, plusNanoseconds: 1)) == .recover)
    }

    @Test("窓から外れた記録を除いて数え直す")
    func staleRecordsLeaveWindow() {
        var breaker = TapTimeoutBreaker()

        #expect(breaker.recordTimeout(at: Self.seconds(100)) == .recover)
        #expect(breaker.recordTimeout(at: Self.seconds(120)) == .recover)
        // 100 秒の記録が外れ、窓の中は 120 と 140 の 2 回
        #expect(breaker.recordTimeout(at: Self.seconds(140)) == .recover)
        // 窓の中は 120、140、145 の 3 回
        #expect(breaker.recordTimeout(at: Self.seconds(145)) == .abandon)
    }

    @Test("間隔が窓より長ければ、何回起きても異常にならない")
    func sparseTimeoutsNeverAbandon() {
        var breaker = TapTimeoutBreaker()

        for index in UInt64(0)..<20 {
            #expect(breaker.recordTimeout(at: Self.seconds(100 + index * 31)) == .recover)
        }
    }

    @Test("15 秒より長い間隔なら、窓の中は 2 回までなので異常にならない")
    func intervalJustOverHalfWindow() {
        var breaker = TapTimeoutBreaker()

        for index in UInt64(0)..<20 {
            #expect(breaker.recordTimeout(at: Self.seconds(100 + index * 16)) == .recover)
        }
    }

    @Test("異常の判定の後も、窓の中で続けば異常のまま")
    func staysAbandonedWithinWindow() {
        var breaker = TapTimeoutBreaker()
        for second in UInt64(100)...101 {
            _ = breaker.recordTimeout(at: Self.seconds(second))
        }

        #expect(breaker.recordTimeout(at: Self.seconds(102)) == .abandon)
        #expect(breaker.recordTimeout(at: Self.seconds(103)) == .abandon)
    }

    @Test("reset: 記録を捨てて数え直す")
    func resetClearsRecords() {
        var breaker = TapTimeoutBreaker()
        _ = breaker.recordTimeout(at: Self.seconds(100))
        _ = breaker.recordTimeout(at: Self.seconds(101))

        breaker.reset()

        #expect(breaker.recordTimeout(at: Self.seconds(102)) == .recover)
        #expect(breaker.recordTimeout(at: Self.seconds(103)) == .recover)
        #expect(breaker.recordTimeout(at: Self.seconds(104)) == .abandon)
    }

    @Test("時刻が戻っても落ちず、数える側に倒す")
    func clockGoesBackwardStillCounts() {
        var breaker = TapTimeoutBreaker()

        #expect(breaker.recordTimeout(at: Self.seconds(100)) == .recover)
        #expect(breaker.recordTimeout(at: Self.seconds(50)) == .recover)
        #expect(breaker.recordTimeout(at: Self.seconds(10)) == .abandon)
    }

    @Test("時刻が戻った記録は前回の時刻として扱うので、その後の窓の計算が狂わない")
    func clockGoesBackwardThenForward() {
        var breaker = TapTimeoutBreaker()

        #expect(breaker.recordTimeout(at: Self.seconds(100)) == .recover)
        // 100 秒として記録される
        #expect(breaker.recordTimeout(at: Self.seconds(50)) == .recover)
        // 100 秒の 2 件はどちらも窓から外れる
        #expect(breaker.recordTimeout(at: Self.seconds(131)) == .recover)
        #expect(breaker.recordTimeout(at: Self.seconds(132)) == .recover)
        #expect(breaker.recordTimeout(at: Self.seconds(133)) == .abandon)
    }

    @Test("時刻 0 でも落ちない")
    func zeroTimestamp() {
        var breaker = TapTimeoutBreaker()

        #expect(breaker.recordTimeout(at: Timestamp(nanoseconds: 0)) == .recover)
        #expect(breaker.recordTimeout(at: Timestamp(nanoseconds: 0)) == .recover)
    }
}
