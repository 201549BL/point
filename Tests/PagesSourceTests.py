"""Run with python3 Tests/PagesSourceTests.py; uses real temporary Git history."""
import importlib.util
import pathlib
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'pages_source', pathlib.Path(__file__).resolve().parents[1] / 'Scripts/check-pages-source.py',
)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class PagesSourceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Pages test')
        self.git('config', 'user.email', 'pages@example.invalid')
        self.old = self.commit('old page')
        self.current = self.commit('interactive playground')
        self.git('update-ref', 'refs/remotes/origin/main', self.current)

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True, stderr=subprocess.PIPE).strip()

    def commit(self, content):
        (self.root / 'index.html').write_text(content)
        self.git('add', 'index.html')
        self.git('commit', '-qm', content)
        return self.git('rev-parse', 'HEAD')

    def test_stale_feature_branch_rejected(self):
        self.git('checkout', '-qb', 'old-feature', self.old)
        self.commit('local blur edit')
        with self.assertRaisesRegex(RuntimeError, 'Stale checkout.*Pages source'):
            gate.check_ancestry(self.root, 'refs/remotes/origin/main', self.current)

    def test_current_branch_with_local_edits_passes_without_touching_edits(self):
        (self.root / 'index.html').write_text('unfinished blur work')
        gate.check_ancestry(self.root, 'refs/remotes/origin/main', self.current)
        self.assertEqual((self.root / 'index.html').read_text(), 'unfinished blur work')

    def test_deployment_missing_from_rewritten_source_rejected(self):
        deployed = self.commit('deployed version')
        self.git('checkout', '--detach', self.current)
        with self.assertRaisesRegex(RuntimeError, 'successful deployment'):
            gate.check_ancestry(self.root, 'refs/remotes/origin/main', deployed)

    def test_new_work_based_on_current_source_passes(self):
        self.commit('new blur work')
        gate.check_ancestry(self.root, 'refs/remotes/origin/main', self.current)


if __name__ == '__main__':
    unittest.main()
