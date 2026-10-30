import Foundation
import Testing
import MotingObjCSupport

@Test func catchesObjectiveCException() {
    let reason = MOTryCatch {
        NSException(name: .internalInconsistencyException, reason: "player did not see an IO cycle.", userInfo: nil).raise()
    }
    #expect(reason == "player did not see an IO cycle.")
}

@Test func returnsNilWithoutException() {
    var ran = false
    #expect(MOTryCatch { ran = true } == nil)
    #expect(ran)
}
