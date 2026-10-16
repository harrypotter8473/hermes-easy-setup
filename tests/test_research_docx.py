"""Word fidelity, audit gates and uncertain delivery boundaries."""
import hashlib
import io
import json
import unittest
import zipfile
from types import SimpleNamespace
from unittest.mock import Mock
from xml.etree import ElementTree as ET
from engine.research_team.report_docx import build_report, inspect_report
from engine.research_team.workflow import AutomaticReportWorkflow
from engine.research_team.broker import Mattermost


class WordReportTests(unittest.TestCase):
    def fixture(self):
        text='# 연구 보고서\n\n## 결론\n불확실성 **유지** <근거> & 출처 https://example.org\n\n| 항목 | 값 |\n| --- | --- |\n| 자료 | 초록만 확인 |'
        ref={'id':'artifact_1','version':1,'sha256':hashlib.sha256(text.encode()).hexdigest(),'role':'manager','scope':'topic','task_id':'task_1'}
        return text, ref

    def test_deterministic_package_retains_exact_audited_text_and_binding(self):
        text, ref=self.fixture(); rid='req_'+'1'*32
        payload=build_report(text,rid,ref)
        self.assertEqual(payload,build_report(text,rid,ref))
        with zipfile.ZipFile(io.BytesIO(payload)) as z:
            for name in z.namelist(): ET.fromstring(z.read(name))
            xml=ET.fromstring(z.read('customXml/item1.xml'))
            self.assertEqual(text,xml.find('{urn:hermes:audited-report:v1}source').text)
            self.assertEqual(ref,json.loads(xml.find('{urn:hermes:audited-report:v1}binding').text)['artifact_ref'])
            self.assertIn('<w:tbl>',z.read('word/document.xml').decode())
            self.assertIn('초록만 확인',z.read('word/document.xml').decode())
            self.assertFalse(any('vba' in name.lower() for name in z.namelist()))

    def test_forged_hash_and_role_rejected(self):
        text,ref=self.fixture()
        for change in ({'sha256':'0'*64},{'role':'researcher'}):
            with self.assertRaises(ValueError): build_report(text,'req_'+'1'*32,{**ref,**change})

    def test_windows_newlines_are_preserved_in_candidate_source(self):
        text, ref = self.fixture()
        text = text.replace('\n', '\r\n')
        ref['sha256'] = hashlib.sha256(text.encode()).hexdigest()
        request = 'req_'+'1'*32
        proof = inspect_report(build_report(text, request, ref), text, request, ref)
        self.assertTrue(proof['source_content_preserved'])

    def test_preview_contains_real_word_bytes_and_exact_source_binding(self):
        text, ref = self.fixture()
        request = 'req_' + '1'*32
        document = build_report(text, request, ref)
        proof = inspect_report(document, text, request, ref)
        self.assertTrue(proof['generated'])
        self.assertTrue(proof['xml_structure_verified'])
        self.assertEqual(hashlib.sha256(document).hexdigest(), proof['sha256'])
        self.assertEqual(len(document), proof['byte_length'])
        self.assertIn('초록만 확인', proof['visible_text'])
        self.assertFalse(proof['visual_layout_verified'])
        self.assertEqual('not_sent_pending_audits', proof['delivery_state'])
        with self.assertRaises(ValueError):
            inspect_report(document, 'different source', request, ref)

    def test_delivery_must_match_final_auditors_word_candidate(self):
        flow, state = self.flow()
        proof = flow.prepare_report(state)
        flow.deliver_report(state)
        uploaded = flow.broker.client.upload_report.call_args.args[1]
        self.assertEqual(proof['sha256'], hashlib.sha256(uploaded).hexdigest())
        flow, state = self.flow()
        proof = flow.prepare_report(state)
        proof['sha256'] = '0'*64
        with self.assertRaisesRegex(ValueError, 'ReportPreviewDeliveryBindingRejected'):
            flow.deliver_report(state)
        flow.broker.client.upload_report.assert_not_called()

    def flow(self):
        text,ref=self.fixture()
        state={'request_id':'req_'+'1'*32,'post_id':'p'*26,'scope':'topic','stage':'reviewed','artifacts':{'manager':ref},'root_task':{'task_id':'task_root'}}
        flow=object.__new__(AutomaticReportWorkflow)
        flow.save=Mock()
        flow.broker=SimpleNamespace(policy=SimpleNamespace(reviewed_report_gate=Mock(return_value=SimpleNamespace(status='pass')),
            assign_task=Mock(return_value='task_read'),read_artifact=Mock(return_value=text.encode())),
            client=SimpleNamespace(upload_report=Mock(return_value='f'*26),verify_report=Mock(return_value=True)),reply=Mock(return_value='env_1'),event=Mock())
        return flow,state

    def test_delivered_file_is_verified_and_not_duplicated(self):
        flow,state=self.flow(); delivery=flow.deliver_report(state)
        self.assertEqual('delivered',delivery['state'])
        self.assertTrue(delivery['download_verified'])
        self.assertEqual(['f'*26],flow.broker.reply.call_args.kwargs['file_ids'])
        flow.deliver_report(state)
        flow.broker.client.upload_report.assert_called_once()
        flow.broker.reply.assert_called_once()

    def test_uncertain_upload_is_never_replayed(self):
        flow,state=self.flow();flow.broker.client.upload_report.side_effect=RuntimeError('timeout')
        for _ in range(2):
            with self.assertRaises(RuntimeError): flow.deliver_report(state)
        flow.broker.client.upload_report.assert_called_once()
        flow.broker.reply.assert_not_called()

    def test_failed_download_can_retry_without_reuploading(self):
        flow,state=self.flow();flow.broker.client.verify_report.side_effect=[RuntimeError('network'),True]
        with self.assertRaises(RuntimeError): flow.deliver_report(state)
        self.assertEqual('uploaded',state['report_delivery']['state'])
        flow.deliver_report(state)
        flow.broker.client.upload_report.assert_called_once()

    def test_failed_audit_never_exports(self):
        flow,state=self.flow();flow.broker.policy.reviewed_report_gate.return_value.status='reject'
        with self.assertRaises(ValueError): flow.deliver_report(state)
        flow.broker.client.upload_report.assert_not_called()

    def test_attachment_only_manager_and_exact_thread(self):
        mm=Mattermost({'server_url':'http://127.0.0.1:18065','channel_id':'c'*26})
        mm.api=Mock(return_value={'id':'p'*26,'channel_id':'c'*26,'root_id':'r'*26,'file_ids':['f'*26]})
        with self.assertRaises(ValueError): mm.post('researcher','r'*26,'report',file_ids=['f'*26])
        self.assertEqual('p'*26,mm.post('manager','r'*26,'report',file_ids=['f'*26]))
        mm.api.return_value['root_id']='x'*26
        with self.assertRaises(RuntimeError):mm.post('manager','r'*26,'report',file_ids=['f'*26])

if __name__=='__main__':unittest.main()
