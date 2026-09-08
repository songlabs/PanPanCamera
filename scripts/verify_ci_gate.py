"""Only a completed, successful iOS CI run at this SHA on main opens the gate."""
import json
from pathlib import Path
import sys


def verify(payload, sha):
    exact = [run for run in payload['workflow_runs']
             if run['head_sha'] == sha and run.get('head_branch') == 'main'
             and run.get('name') == 'iOS CI']
    for run in exact:
        if run['status'] == 'completed' and run.get('conclusion') == 'success':
            return f'iOS CI passed for current commit {sha}: {run["html_url"]}'
    if not exact:
        reason = 'No iOS CI run exists for the current commit on main.'
    elif any(run['status'] != 'completed' for run in exact):
        reason = 'iOS CI has not completed successfully for the current commit. Wait and retry.'
    else:
        reason = 'iOS CI did not succeed: ' + ', '.join(str(run.get('conclusion')) for run in exact)
    raise ValueError(reason + ' TestFlight aborted before signing and Archive.')


if __name__ == '__main__':
    try:
        print(verify(json.loads(Path(sys.argv[1]).read_text()), sys.argv[2]))
    except (ValueError, KeyError) as error:
        sys.exit(str(error))
