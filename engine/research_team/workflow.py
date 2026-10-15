"""Program-owned report pipeline; models supply content, never the routing graph.

Every transition is persisted. A crash during a model/tool action is deliberately
held for review by Broker; only a clean held checkpoint can be resumed. Reports
are reviewed drafts, not human-approved publications.
"""
from __future__ import annotations

import json
import re
import hashlib
import time

if __package__:
    from .report_docx import build_report
else:
    from report_docx import build_report


class AutomaticReportWorkflow:
    VERSION = 1
    RETRY_DELAYS = (2, 5, 10)
    STAGES = ("plan", "research", "research_audit", "analysis", "analysis_audit",
              "synthesis", "synthesis_audit", "final_audit", "reviewed")
    ROLE = {"plan": "manager", "research": "researcher", "research_audit": "auditor",
            "analysis": "analyst", "analysis_audit": "auditor", "synthesis": "manager",
            "synthesis_audit": "auditor", "final_audit": "auditor"}

    def __init__(self, broker):
        self.broker = broker
        broker.db.execute("CREATE TABLE IF NOT EXISTS workflows(request_id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
        broker.db.commit()

    def load(self, request_id):
        row = self.broker.db.execute("SELECT payload FROM workflows WHERE request_id=?", (request_id,)).fetchone()
        return json.loads(row[0]) if row else None

    def save(self, state):
        self.broker.db.execute("INSERT OR REPLACE INTO workflows VALUES(?,?)",
                               (state["request_id"], json.dumps(state, ensure_ascii=False)))
        self.broker.db.commit()

    def start(self, post_id, request_id, scope, objective, root_task):
        state = {"version": self.VERSION, "post_id": post_id, "request_id": request_id,
                 "scope": scope, "objective": objective, "stage": "plan", "root_task": root_task,
                 "task": root_task, "artifacts": {}, "plan": "", "revision_notes": {},
                 "model_retries": 0, "tool_failures": 0, "search_evidence": [], "read_evidence": [],
                 "stage_actions": [], "role_runs": {}, "previous_outputs": {}, "completed_stages": [], "status": "running"}
        self.save(state)
        return self.run(request_id)

    def _dependencies(self, state, stage):
        refs = state["artifacts"]
        if stage in ("research_audit", "analysis"):
            return [refs["researcher"]]
        if stage == "analysis_audit":
            return [refs["analyst"]]
        if stage == "synthesis":
            return [refs["researcher"], refs["analyst"]]
        if stage == "synthesis_audit":
            return [refs["manager"]]
        if stage == "final_audit":
            return [refs[role] for role in ("researcher", "analyst", "manager")]
        return []

    def _assign(self, state):
        broker, stage = self.broker, state["stage"]
        role = self.ROLE[stage]
        phase = "audit" if role == "auditor" else ("prepare" if role == "manager" else "main")
        dependencies = self._dependencies(state, stage)
        audit_stage = "final" if stage == "final_audit" else ("intermediate" if role == "auditor" else None)
        instructions = ("Automatic report stage: " + stage + "\nRequested report: " + state["objective"] +
                        "\nManager plan: " + state["plan"] + "\nAssigned revision issues: " +
                        json.dumps(state["revision_notes"].get(role, []), ensure_ascii=False))
        task_id = broker.policy.assign_task(state["request_id"], actor_role="manager", target_role=role,
            scope=state["scope"], instructions=instructions, dependencies=dependencies,
            phase=phase, audit_stage=audit_stage)
        task = {"task_id": task_id, "role": role, "scope": state["scope"], "instructions": instructions,
                "phase": phase, "dependencies": dependencies, "audit_stage": audit_stage}
        task["_delivery_envelope_id"] = broker._send_envelope(
            state["request_id"], task_id, "manager", role, "task", state["post_id"],
            "@" + broker.service["bots"][role]["username"] + " " + stage +
            " 작업을 할당했습니다. 요청 ID: " + state["request_id"],
            source_task_id=state["root_task"]["task_id"])
        state["task"], state["stage_actions"], state["model_retries"] = task, [], 0
        state["tool_failures"] = 0
        self.save(state)

    def _context(self, state):
        broker, task, stage = self.broker, state["task"], state["stage"]
        role = task["role"]
        context = broker.task_context(state["post_id"], state["request_id"], task)
        context["automatic_workflow"] = {"stage": stage, "objective": state["objective"],
            "scope": state["scope"], "routing_owner": "program", "manager_plan": state["plan"],
            "output_scope_token": "scope_" + hashlib.sha256(state["scope"].encode("utf-8")).hexdigest(),
            "output_scope_rule": "For action scope and artifact_ref.scope use output_scope_token. The program restores the exact original scope before authorization.",
            "max_original_sources": 3, "source_context_character_limit": 100000,
            "revision_issues": state["revision_notes"].get(role, []),
            "previous_own_output": state["previous_outputs"].get(role),
            "stage_results": state["stage_actions"], "output_name": "report" if role == "manager" else role,
            "required_behavior": {
                "plan": "Return the division-of-work plan in message, with actions: []. The program will dispatch all four roles; do not write the report or dispatch directly.",
                "research": "Use search_web, then read_web on an actual result in a subsequent turn. Search and public-source access are already enabled and enforced by the program; an absent user domain list is not missing permission. Read up to 3 relevant originals; select at most two initial search queries and prioritize reading good results rather than repeated searches. Once sufficient evidence is captured, write_artifact named researcher with source URLs and evidence. Do not answer from memory or skip tools.",
                "analysis": "Analyze the assigned, audited research originals. Write_artifact named analyst, with reasoning, source attribution, and limitations.",
                "synthesis": "Synthesize only the assigned audited research and analysis into the requested Korean report. Write_artifact named report. Preserve uncertainty and citations; do not dispatch or complete.",
            }.get(stage, "Inspect every assigned original artifact and previous audit issues. Return one audit action per exact dependency at the assigned audit_stage, with pass/reject/unverifiable and concrete evidence. Never modify originals."),
            "allowed_actions": (["search_web", "read_web", "read_text", "write_artifact"] if role == "researcher"
                else ["audit"] if role == "auditor" else [] if stage == "plan" else ["read_text", "write_artifact"])}
        if stage == "research":
            # Only offer actions that can currently succeed. This avoids paying
            # for a fabricated report before search/read evidence exists.
            if not state["search_evidence"]:
                actions = ["search_web"]
            elif not state["read_evidence"]:
                actions = ["search_web", "read_web"]
            elif len(state["read_evidence"]) >= 3:
                actions = ["write_artifact"]
            else:
                actions = ["search_web", "read_web", "write_artifact"]
            context["automatic_workflow"]["allowed_actions"] = actions
        if state.get("last_error"):
            context["automatic_workflow"]["last_error"] = state["last_error"]
        if state.get("retry_feedback"):
            context["automatic_workflow"]["retry_feedback"] = state["retry_feedback"]
        # Original fetched sources are research inputs, not ambient bot chat.
        # Reviewers receive the actual captured text, including provenance,
        # rather than only the author's summary or invented citation strings.
        sources, remaining = [], 100000
        for evidence in broker.policy.list_web_evidence(state["request_id"]):
            if evidence["tool"] != "read_web":
                continue
            source = dict(evidence["result"])
            original = source.get("text", "")
            excerpt = original[:max(0, remaining)]
            remaining -= len(excerpt)
            source.update(text=excerpt, workflow_excerpt=len(excerpt) != len(original),
                          stored_text_characters=len(original), evidence_id=evidence["id"])
            if len(excerpt) != len(original):
                source["truncated"] = True
                source["limitation"] = "Only this explicit excerpt is in model context; do not claim the omitted original was checked. Full captured text remains in immutable evidence."
            sources.append(source)
        context["untrusted_web_sources"] = sources
        return context

    def _notice(self, state, message):
        broker, role, task = self.broker, state["task"]["role"], state["task"]
        safe = broker._neutralize_mentions(message or "작업 상태를 기록했습니다.")
        if role == "manager":
            return broker.reply(role, state["post_id"], safe[:11500], request_id=state["request_id"],
                task_id=task["task_id"], kind="bot_status")
        envelope = broker.reply(role, state["post_id"],
            "@" + broker.service["bots"]["manager"]["username"] + " " + safe[:11000],
            request_id=state["request_id"], task_id=state["root_task"]["task_id"],
            source_task_id=task["task_id"], target_role="manager", kind="bot_result")
        return envelope

    def _advance(self, state, next_stage):
        state["completed_stages"].append(state["stage"])
        self.broker.event(state["request_id"], self.ROLE[state["stage"]], "workflow_stage", "passed",
                          {"stage": state["stage"], "task_id": state["task"]["task_id"]})
        state["stage"], state["task"], state["last_error"] = next_stage, None, None
        self.save(state)

    def _audit_transition(self, state):
        expected = state["task"]["dependencies"]
        audits = {item["artifact_ref"]["id"]: item for item in state["stage_actions"] if "audit_id" in item}
        if any(ref["id"] not in audits for ref in expected):
            return False
        failed = [audits[ref["id"]] for ref in expected if audits[ref["id"]]["verdict"] != "pass"]
        if failed:
            # Regenerate the earliest failed producer and every dependent stage.
            # New immutable versions consume revision budget; no previous pass
            # can authorize a changed artifact.
            order = {"researcher": 0, "analyst": 1, "manager": 2}
            role = min((item["artifact_ref"]["role"] for item in failed), key=order.__getitem__)
            state["revision_notes"][role] = [item["report"] for item in failed if item["artifact_ref"]["role"] == role]
            for target in ("researcher", "analyst", "manager"):
                if order[target] > order[role]:
                    state["artifacts"].pop(target, None)
            self.broker.event(state["request_id"], "auditor", "revision", "required",
                              {"role": role, "stage": state["stage"], "audits": [item["audit_id"] for item in failed]})
            self._notice(state, "감사에서 보완이 필요하여 " + role + " 담당에게 수정·재검사를 요청했습니다.")
            self._advance(state, {"researcher": "research", "analyst": "analysis", "manager": "synthesis"}[role])
        else:
            self._advance(state, {"research_audit": "analysis", "analysis_audit": "synthesis",
                                 "synthesis_audit": "final_audit", "final_audit": "reviewed"}[state["stage"]])
        return True

    def _validate_actions(self, state, answer):
        stage, role = state["stage"], state["task"]["role"]
        actions = answer["actions"]
        if stage == "plan" and not answer["message"].strip():
            raise ValueError("AutomaticPlanMissing")
        if stage != "plan" and not actions:
            raise ValueError("AutomaticActionMissing")
        if len(actions) > 8:
            raise ValueError("AutomaticActionBatchTooLarge")
        allowed = set(self._context(state)["automatic_workflow"]["allowed_actions"])
        if any(not isinstance(action, dict) or action.get("tool") not in allowed for action in actions):
            raise ValueError("AutomaticRoutingCannotBeOverridden")
        writes = [action for action in actions if action.get("tool") == "write_artifact"]
        if len(state["read_evidence"]) + sum(action.get("tool") == "read_web" for action in actions) > 3:
            raise ValueError("AutomaticSourceReadLimitReached")
        if len(writes) > 1 or (writes and len(actions) != 1):
            raise ValueError("ArtifactMustFollowObservedToolResults")
        if writes:
            expected_name = "report" if role == "manager" else role
            if writes[0].get("name") != expected_name:
                raise ValueError("AutomaticArtifactNameRejected")
            if writes[0].get("scope") != state["scope"]:
                raise ValueError("AutomaticArtifactScopeRejected")
            if not isinstance(writes[0].get("content"), str) or not writes[0]["content"].strip():
                raise ValueError("AutomaticArtifactContentRejected")
            if role == "researcher" and not (state["search_evidence"] and state["read_evidence"]):
                raise ValueError("ResearchMustObserveSearchAndOriginalSources")
        existing = {item["artifact_ref"]["id"] for item in state["stage_actions"] if "audit_id" in item}
        for action in actions:
            if action["tool"] == "read_web":
                if len(state["read_evidence"]) >= 3:
                    raise ValueError("AutomaticSourceReadLimitReached")
                urls = {item.get("url") for result in state["stage_actions"]
                        if result.get("tool") == "search_web" for item in result.get("results", [])}
                if action.get("url") not in urls:
                    raise ValueError("ReadMustUseObservedSearchResult")
            if action["tool"] == "audit":
                ref = action.get("artifact_ref")
                if (ref not in state["task"]["dependencies"] or action.get("stage") != state["task"]["audit_stage"] or
                        action.get("scope") != state["scope"] or ref["id"] in existing or
                        not isinstance(action.get("notes"), str) or not action["notes"].strip()):
                    raise ValueError("AutomaticAuditBindingRejected")
                existing.add(ref["id"])

    def _hold(self, state, reason, *, status="held"):
        previous = state.get("last_error")
        if isinstance(previous, str) and previous and previous != reason:
            reason += " (" + previous[:240] + ")"
        state["status"], state["last_error"] = status, reason
        self.save(state)
        broker = self.broker
        broker.save(state["post_id"], status, state["request_id"], state["scope"], [])
        label = "자동 분업을 중단했습니다: " if status == "failed" else "자동 분업을 보류했습니다: "
        broker.reply("manager", state["post_id"], label + reason +
            ". 요청 ID: " + state["request_id"], request_id=state["request_id"],
            task_id=state["root_task"]["task_id"], kind="bot_status")
        return state

    def _retry_model(self, state, error):
        """Only repeat model generation before an action batch has executed."""
        code = str(error)
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,100}", code):
            code = type(error).__name__
        transient = {
            "HermesWorker_MODEL_RATE_LIMITED", "HermesWorker_MODEL_TRANSIENT_ERROR",
            "HermesWorker_MODEL_CONNECTION_FAILED", "HermesWorker_HERMES_CALL_FAILED",
            "HermesWorker_MODEL_RESPONSE_FAILED", "ModelWallClockLimitExceeded",
        }
        repairable = {
            "HermesWorker_MODEL_OUTPUT_NOT_JSON", "HermesWorker_MODEL_OUTPUT_SCHEMA_INVALID",
            "HermesWorker_MODEL_OUTPUT_INCOMPLETE", "HermesWorker_MODEL_OUTPUT_TRUNCATED",
            "ModelActionEnvelopeRejected", "ModelActionScopeBindingRejected",
            "AutomaticActionMissing", "AutomaticPlanMissing", "AutomaticActionBatchTooLarge",
            "ArtifactMustFollowObservedToolResults", "AutomaticArtifactNameRejected",
            "AutomaticArtifactScopeRejected", "AutomaticArtifactContentRejected",
            "ResearchMustObserveSearchAndOriginalSources", "ReadMustUseObservedSearchResult",
            "AutomaticAuditBindingRejected", "AutomaticSourceReadLimitReached",
        }
        category = "transient" if code in transient else "format" if code in repairable else "permanent"
        state["last_error"] = code
        state["model_retries"] = state.get("model_retries", 0) + 1
        attempt = state["model_retries"]
        retry = category != "permanent" and attempt <= len(self.RETRY_DELAYS)
        delay = self.RETRY_DELAYS[attempt - 1] if retry else 0
        self.broker.event(state["request_id"], state["task"]["role"], "model_retry",
                          "retry" if retry else "held", {"stage": state["stage"], "retry": attempt,
                          "reason": code, "category": category, "delay_seconds": delay})
        if category == "format":
            state["retry_feedback"] = {
                "error_code": code,
                "instruction": "Regenerate one complete JSON response matching the provided schema. Use output_scope_token exactly. Keep messages concise and fit the output cap. Execute only the next allowed stage action; do not repeat already observed actions. If original-source limit is reached, use captured sources and state limitations. Never invent successful tool results, IDs, approvals or audit passes.",
            }
        self.save(state)
        if not retry:
            reason = ("모델 인증·사용 한도 또는 요청 규격 오류로 자동 복구를 중단했습니다"
                      if category == "permanent" else "자동 재시도 3회 후에도 복구되지 않았습니다")
            self._hold(state, reason)
            return False
        label = "일시적인 모델 연결 오류" if category == "transient" else "모델 응답 형식 오류"
        self.broker.reply("manager", state["post_id"],
            f"{label}를 감지했습니다. {delay}초 후 {state['stage']} 작업을 자동 재시도합니다 ({attempt}/3).",
            request_id=state["request_id"], task_id=state["root_task"]["task_id"], kind="bot_status")
        time.sleep(delay)
        return True

    def run(self, request_id):
        state = self.load(request_id)
        if state is None or state["version"] != self.VERSION:
            raise ValueError("AutomaticWorkflowMissing")
        if state["status"] == "reviewed":
            return state
        if state["status"] == "failed":
            raise ValueError("AutomaticFailedRequestCannotResume")
        if state["status"] == "held":
            # A deliberate resume starts a new bounded recovery cycle. The
            # persisted per-request time/token/attempt budgets are never reset.
            state["model_retries"] = 0
            state.pop("retry_feedback", None)
        broker = self.broker
        state["status"] = "running"
        while state["stage"] != "reviewed":
            if state["task"] is None:
                self._assign(state)
            task, role = state["task"], state["task"]["role"]
            broker.save(state["post_id"], "running", request_id, state["scope"], [])
            self.save(state)
            try:
                answer = broker.turn(request_id, role, self._context(state))
                self._validate_actions(state, answer)
            except (ValueError, RuntimeError) as error:
                # Only retry before any requested action is executed. A paid
                # physical call still consumes its reserved budget on failure.
                if type(error).__name__ in ("PolicyHold", "PolicyViolation", "BudgetExceeded"):
                    state["last_error"] = type(error).__name__
                    if type(error).__name__ == "BudgetExceeded":
                        return self._hold(state, "설정된 실행 한도에 도달했습니다. 확보한 자료와 실패 기록을 보존했습니다", status="failed")
                    return self._hold(state, "실행 권한 또는 정책 확인이 필요합니다")
                if self._retry_model(state, error):
                    continue
                return state
            if state.get("model_retries"):
                broker.event(request_id, role, "model_retry", "recovered",
                             {"stage": state["stage"], "retries": state["model_retries"]})
                broker.reply("manager", state["post_id"], "자동 재시도가 성공하여 작업을 계속합니다.",
                    request_id=request_id, task_id=state["root_task"]["task_id"], kind="bot_status")
            state["model_retries"], state["last_error"] = 0, None
            state.pop("retry_feedback", None)
            state["role_runs"][role] = state["role_runs"].get(role, 0) + 1
            self._notice(state, answer["message"])
            if state["stage"] == "plan":
                if not answer["message"].strip():
                    return self._hold(state, "총괄의 분업 계획이 비어 있습니다")
                state["plan"] = answer["message"]
                self._advance(state, "research")
                continue
            if not answer["actions"]:
                return self._hold(state, "담당 에이전트가 필요한 도구 실행 또는 결과를 제출하지 않았습니다")
            for action in answer["actions"]:
                broker.event(request_id, role, "tool", "started", {"task_id": task["task_id"], "tool": action["tool"]})
                try:
                    result = broker.action(request_id, task["task_id"], role, action)
                except RuntimeError as error:
                    if action["tool"] not in ("search_web", "read_web") or type(error).__name__ != "WebToolError":
                        raise
                    # Fetches are read-only; one bounded network retry is safe.
                    # The web adapter reserves its own attempts/time each time.
                    broker.event(request_id, role, "web_retry", "retry", {"tool": action["tool"]})
                    broker.reply('manager', state['post_id'], '자료 접근이 일시적으로 실패하여 5초 후 다시 시도합니다. 계속 실패하면 다른 검색어·자료를 검토합니다.',
                        request_id=request_id, task_id=state['root_task']['task_id'], kind='bot_status')
                    time.sleep(5)
                    try:
                        result = broker.action(request_id, task["task_id"], role, action)
                    except RuntimeError as repeated:
                        if type(repeated).__name__ != "WebToolError":
                            raise
                        state["tool_failures"] += 1
                        result = {"ok": False, "tool": action["tool"], "tool_error": str(repeated)[:240],
                                  "retry_or_select_another_source": state["tool_failures"] < 2,
                                  "research_hint": "For relevant academic topics, search_web with site:arxiv.org and a short English query uses the official arXiv metadata API. Metadata is not an original read; still use read_web on a returned source. Do not change the user's topic or claim comprehensive web coverage."}
                        state["stage_actions"].append(result)
                        state["last_error"] = "WebToolError: " + str(repeated)[:240]
                        broker.event(request_id, role, "tool", "failed", {"task_id": task["task_id"],
                            "tool": action["tool"], "failed_actions_in_stage": state["tool_failures"]})
                        self.save(state)
                        if state["tool_failures"] >= 2:
                            return self._hold(state, "자료 검색·원문 읽기의 재시도 한도에 도달했습니다")
                        continue
                # The same captured source is sent exactly once in the dedicated
                # provenance section; action feedback keeps only its reference.
                if action["tool"] == "read_web" and "text" in result:
                    result = {key: value for key, value in result.items() if key != "text"}
                    result["content_in"] = "untrusted_web_sources"
                state["stage_actions"].append(result)
                broker.event(request_id, role, "tool", "returned", {"task_id": task["task_id"], "tool": action["tool"],
                    "result": result if "artifact_ref" in result or "audit_id" in result else
                    {key: result[key] for key in ("ok", "evidence_id", "request_id", "task_id", "source_url", "response_sha256") if key in result}})
                if action["tool"] in ("search_web", "read_web"):
                    if not (result.get("ok") is True and result.get("evidence_id") and result.get("request_id") == request_id and result.get("task_id") == task["task_id"]):
                        raise ValueError("ResearchWebEvidenceBindingRejected")
                    state["search_evidence" if action["tool"] == "search_web" else "read_evidence"].append(result["evidence_id"])
                if "artifact_ref" in result and action["tool"] == "write_artifact":
                    state["artifacts"][role] = result["artifact_ref"]
                    state["previous_outputs"][role] = {"ref": result["artifact_ref"], "content": action["content"]}
                self.save(state)
            if role == "auditor":
                self._audit_transition(state)
            elif any("artifact_ref" in result for result in state["stage_actions"]):
                self._advance(state, {"research": "research_audit", "analysis": "analysis_audit",
                                     "synthesis": "synthesis_audit"}[state["stage"]])
            self.save(state)
        gate = broker.policy.reviewed_report_gate(request_id, scope=state["scope"])
        if gate.status != "pass":
            return self._hold(state, "최신 결과물의 감사 기록이 완전하지 않습니다")
        try:
            self.deliver_report(state)
        except (RuntimeError, ValueError) as error:
            broker.event(request_id, 'manager', 'report_delivery', 'held', {'reason': type(error).__name__})
            return self._hold(state, '보고서 검토는 끝났지만 Word 파일 전달 확인이 필요합니다. 중복 전송을 방지하기 위해 전송 기록을 보존했습니다')
        state["status"] = "reviewed"
        broker.event(request_id, "manager", "automatic_report", "reviewed", {"artifacts": state["artifacts"]})
        self.save(state)
        broker.save(state["post_id"], "reviewed", request_id, state["scope"], [])
        return state

    def deliver_report(self, state):
        """Program-only export; persist before each write, never replay uncertain sends."""
        broker, request_id = self.broker, state['request_id']
        if state['stage'] != 'reviewed' or broker.policy.reviewed_report_gate(request_id, scope=state['scope']).status != 'pass':
            raise ValueError('ReportAuditGateRejected')
        delivery = state.get('report_delivery', {})
        if delivery.get('state') == 'delivered':
            if delivery.get('artifact_ref') != state['artifacts']['manager']:
                raise ValueError('ReportDeliveryVersionRejected')
            return delivery
        if delivery.get('state') in ('uploading', 'sending'):
            raise RuntimeError('ReportDeliveryUncertainRequiresReview')
        report = state["artifacts"]["manager"]
        # Integration task is the stored owner; data is read through an explicit
        # policy dependency rather than a model-controlled filesystem path.
        reader = broker.policy.assign_task(request_id, actor_role="manager", target_role="auditor",
            scope=state["scope"], instructions="Read the exact reviewed report for thread delivery.",
            dependencies=[report], phase="audit", audit_stage="final")
        content = broker.policy.read_artifact(request_id, reader, role="auditor", artifact_ref=report).decode("utf-8")
        document = build_report(content, request_id, report)
        digest = hashlib.sha256(document).hexdigest()
        filename = 'research-report-' + request_id + '.docx'
        if not delivery:
            delivery = {'state': 'uploading', 'filename': filename, 'sha256': digest, 'artifact_ref': report}
            state['report_delivery'] = delivery
            self.save(state)
            delivery['file_id'] = broker.client.upload_report(filename, document)
            delivery['state'] = 'uploaded'
            self.save(state)
        if delivery.get('sha256') != digest or delivery.get('artifact_ref') != report:
            raise ValueError('ReportDeliveryVersionRejected')
        broker.client.verify_report(delivery['file_id'], digest)
        delivery['state'], delivery['download_verified'] = 'sending', True
        self.save(state)
        envelope = broker.reply('manager', state['post_id'],
            '조사·분석·중간 감사·최종 감사를 마친 Word 보고서를 첨부합니다. 외부 배포·공식 최종 승인은 별도 사용자 확인 대상입니다. 요청 ID: ' + request_id,
            request_id=request_id, task_id=state['root_task']['task_id'], kind='bot_status', file_ids=[delivery['file_id']])
        delivery['state'], delivery['envelope_id'] = 'delivered', envelope
        self.save(state)
        broker.event(request_id, 'manager', 'report_delivery', 'delivered', delivery)
        return delivery
