import Foundation
import Observation

/// One step of a job with its log.
struct StepLog: Identifiable, Hashable, Sendable {
    var step: WorkflowJob.Step
    var lines: [LogLine]
    var id: Int { step.number }
}

/// Follows one job's log while the job runs, and stops once the job has
/// ended and the log is complete. Forgejo knows a job's steps, so the log is
/// read step by step: a finished step once, the running one every two
/// seconds. A server that does not tell the steps gets the whole log read
/// in one piece instead, only the new bytes each time.
@MainActor @Observable
final class LogFollower {
    private(set) var steps: [StepLog] = []
    /// The log in one piece, when the server gave no steps.
    private(set) var whole: [LogLine] = []
    private(set) var state: CheckState = .unknown
    private(set) var error: String?
    /// True while the follower still expects more output.
    private(set) var live = false
    private(set) var loaded = false

    /// Every line, in order.
    var lines: [LogLine] { steps.isEmpty ? whole : steps.flatMap(\.lines) }

    private var task: Task<Void, Never>?

    func follow(_ target: LogTarget, client: ForgejoClient) {
        stop()
        steps = []
        whole = []
        state = .unknown
        error = nil
        live = true
        loaded = false
        task = Task { [weak self] in
            var tail = LogTail()
            var done: Set<Int> = [] // steps whose log is final
            var logs: [Int: [LogLine]] = [:]
            var stepTails: [Int: LogTail] = [:] // where each step's next read starts
            // An older server may ignore ?step= and answer every step with the
            // whole log; then the log is read in one piece instead.
            var stepsWork = true
            while !Task.isCancelled {
                // Read the state first: output written before the job ended
                // is then certainly in the reads that follow.
                var job = try? await client.job(target.repo, id: target.jobID)
                if job == nil {
                    job = (try? await client.jobs(target.repo, run: target.runID))?.first { $0.id == target.jobID }
                }
                let finished = job?.state.isFinished ?? false
                var failure: String?
                var fresh: [LogLine] = []
                let jobSteps = stepsWork ? (job?.steps ?? []) : []

                if jobSteps.isEmpty {
                    do {
                        if let data = try await client.jobLog(target.repo, job: target.jobID, from: tail.offset) {
                            fresh = tail.append(data)
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        failure = error.localizedDescription
                    }
                    if finished { fresh += tail.flush() }
                } else {
                    for step in jobSteps where !done.contains(step.number) {
                        guard step.started != nil || step.state.isFinished else { continue }
                        do {
                            var stepTail = stepTails[step.number] ?? LogTail()
                            if let data = try await client.stepLog(target.repo, job: target.jobID, step: step.number, from: stepTail.offset) {
                                logs[step.number, default: []] += stepTail.append(data)
                            }
                            if step.state.isFinished {
                                logs[step.number, default: []] += stepTail.flush()
                                done.insert(step.number)
                            }
                            stepTails[step.number] = stepTail
                        } catch is CancellationError {
                            return
                        } catch {
                            failure = error.localizedDescription
                        }
                    }
                }

                if !jobSteps.isEmpty, stepsWork {
                    let filled = logs.values.filter { !$0.isEmpty }
                    if filled.count >= 2, Set(filled.map { $0.map(\.text) }).count < filled.count {
                        stepsWork = false
                        logs = [:]
                        stepTails = [:]
                        done = []
                        continue
                    }
                }
                guard let self, !Task.isCancelled else { return }
                if let job { self.state = job.state }
                self.error = failure
                if jobSteps.isEmpty {
                    if !fresh.isEmpty { self.whole.append(contentsOf: fresh) }
                } else {
                    let updated = jobSteps.map { StepLog(step: $0, lines: logs[$0.number] ?? []) }
                    if updated != self.steps { self.steps = updated }
                }
                self.loaded = true
                if finished {
                    self.live = false
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        live = false
    }
}
