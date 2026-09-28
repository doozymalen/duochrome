import Foundation

/// 뒤 작업 문지기: 애플 RAW 해독기는 해독을 한 줄로 세워 처리한다(RawCamera 내부 직렬 큐).
/// 그래서 뒤에서 RAW를 풀면(썸네일·미리보기·안개 빛·색조 분포) 지금 보는 사진의 해독이 그 뒤에 줄을 선다.
/// 사용자가 무언가 하는 동안(사진 열기·그리기·값 바꾸기)은 뒤 작업이 RAW를 풀기 전에 잠깐 기다린다.
enum BackgroundGate {
    private static let lock = NSLock()
    private static var last: CFAbsoluteTime = 0
    /// 이만큼 조용하면 뒤 작업을 한다 (초)
    static var quiet: Double = 0.8
    /// 긴 앞 작업(내보내기 등)이 진행 중인 수
    private static var busy = 0

    /// 긴 앞 작업 동안 뒤 작업을 세운다 (내보내기처럼 주 스레드가 오래 안 돌아와도 쉬는 걸로 보이지 않게)
    static func during<T>(_ f: () throws -> T) rethrows -> T {
        lock.lock(); busy += 1; lock.unlock()
        defer { lock.lock(); busy -= 1; last = CFAbsoluteTimeGetCurrent(); lock.unlock() }
        return try f()
    }

    /// 앞에서 무언가 했다 (주 스레드에서 부른다)
    static func touch() {
        lock.lock(); last = CFAbsoluteTimeGetCurrent(); lock.unlock()
    }

    /// 뒤 스레드: 앞이 조용해질 때까지 기다린다 (최대 `limit`초 — 영영 막히지 않게)
    static func waitQuiet(limit: Double = 20) {
        guard !Thread.isMainThread else { return }
        let start = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - start < limit {
            lock.lock(); let idle = CFAbsoluteTimeGetCurrent() - last; let working = busy > 0; lock.unlock()
            if idle >= quiet && !working { return }
            Thread.sleep(forTimeInterval: max(0.05, min(0.2, quiet - idle + 0.01)))
        }
    }
}
