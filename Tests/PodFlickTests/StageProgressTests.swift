import XCTest
@testable import PodFlick

/// The pure Stage → progress mapping that drives the window stepper and the
/// status-menu bar. No device, no ffmpeg — just numbers.
final class StageProgressTests: XCTestCase {
    private typealias Stage = SyncModel.Stage

    func testActiveStepMapsEachRunningPhaseToAStep() {
        XCTAssertEqual(Stage.probing.activeStep, 0)
        XCTAssertEqual(Stage.converting(0.5).activeStep, 1)
        XCTAssertEqual(Stage.copying(0.5).activeStep, 2)
        XCTAssertEqual(Stage.updatingDatabase.activeStep, 2)
    }

    func testActiveStepIsNilForNonRunningStates() {
        XCTAssertNil(Stage.waiting.activeStep)
        XCTAssertNil(Stage.done.activeStep)
        XCTAssertNil(Stage.failed("boom").activeStep)
    }

    func testEveryActiveStepIndexesStepTitles() {
        for stage in [Stage.probing, .converting(0), .copying(0), .updatingDatabase] {
            let step = try? XCTUnwrap(stage.activeStep)
            XCTAssertNotNil(step)
            if let step { XCTAssertTrue(Stage.stepTitles.indices.contains(step)) }
        }
    }

    func testStepFractionOnlyForConvertAndCopy() {
        XCTAssertEqual(Stage.converting(0.4).stepFraction, 0.4)
        XCTAssertEqual(Stage.copying(0.9).stepFraction, 0.9)
        XCTAssertNil(Stage.probing.stepFraction)
        XCTAssertNil(Stage.updatingDatabase.stepFraction)
        XCTAssertNil(Stage.waiting.stepFraction)
    }

    func testOverallProgressNeverGoesBackwardsAcrossThePipeline() {
        let ordered: [Stage] = [
            .probing,
            .converting(0), .converting(1),
            .copying(0), .copying(1),
            .updatingDatabase,
        ]
        let values = ordered.map { $0.overallProgress ?? -1 }
        XCTAssertFalse(values.contains(-1), "every running phase reports a bar value")
        // Phase boundaries meet exactly (convert-end == copy-start == 0.80);
        // the epsilon only absorbs the float wobble of that coincident sum.
        for (earlier, later) in zip(values, values.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier, later + 1e-9, "progress must be monotonic")
        }
        XCTAssertGreaterThan(values.first!, 0)
        XCTAssertLessThan(values.last!, 1, "the DB write leaves headroom before done")
    }

    func testOverallProgressIsNilForNonRunningStates() {
        XCTAssertNil(Stage.waiting.overallProgress)
        XCTAssertNil(Stage.done.overallProgress)
        XCTAssertNil(Stage.failed("boom").overallProgress)
    }
}
