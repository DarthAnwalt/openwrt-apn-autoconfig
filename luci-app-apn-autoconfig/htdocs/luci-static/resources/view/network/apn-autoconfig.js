'use strict';
'require view';
'require form';
'require fs';
'require uci';
'require ui';
'require poll';
'require dom';
'require rpc';

/* Frontend v2 — see docs/frontend-contract-v2.md and docs/frontend-states-v2.md.
 *
 * The structural change from v1 is one sentence: navigation and action scope
 * stop being the same control. v1's target selector chose what was displayed
 * and what a button would act on at the same time, which cannot carry a modem
 * that contains slots, endpoints and profiles. Here, where you are is
 * navigation, and what an operation acts on is stated by the operation.
 *
 * Every control the page draws is registered under an id from the contract's
 * control catalogue, and every control node carries that id in the rendered
 * tree. A control that would need an id the catalogue does not have is a
 * control this page may not draw. */

var queryCommand = '/usr/libexec/apn-autoconfig-query';
var controlCommand = '/usr/libexec/apn-autoconfig-control';
var modemQueryCommand = '/usr/libexec/apn-autoconfig-modem-query';
var modemControlCommand = '/usr/libexec/apn-autoconfig-modem-control';
/* The two eSIM wrappers. The read-only one is not harmless by virtue of its
 * name: `profiles` and `notifications` reach the card, and on a modem
 * ModemManager owns that means an inhibit -- no SIM, no bearer, no Internet
 * for the duration. They are reached from a control a person pressed and from
 * nowhere else, which is what tests/test-luci-v2-loading.js sweeps for. */
var esimQueryCommand = '/usr/libexec/apn-autoconfig-esim-query';
var esimControlCommand = '/usr/libexec/apn-autoconfig-esim-control';

function call(command, args, env) {
	/* An environment is passed only when there is something in it, and that is
	 * not tidiness. rpcd refuses `file exec` outright when a session-scoped
	 * caller sends an `env` object at all -- `if (sid && env) return
	 * UBUS_STATUS_PERMISSION_DENIED;` -- so an empty one denies an operation
	 * that needed no environment in the first place. Measured on the reference
	 * router 2026-09-02: every eSIM operation failed with "Permission denied"
	 * before this, including the consented read takeover. */
	var request = env && Object.keys(env).length
		? fs.exec(command, args, env) : fs.exec(command, args);
	return request.then(function(result) {
		var parsed = null;
		try {
			parsed = JSON.parse(result.stdout);
		}
		catch (e) {
			parsed = null;
		}

		/* A read that ran out of time answers with what it did obtain and exits
		 * retryable. That is not a command that failed: treating it as one
		 * would replace a page saying what is known with a page saying
		 * nothing, which is the outcome this whole mechanism exists to stop. */
		if (parsed && typeof parsed === 'object' && parsed.incomplete === true)
			return parsed;

		if (result.code !== 0) {
			/* Mutating wrappers keep a non-zero shell exit for scripts while
			 * returning their refusal as a versioned document. Prefer that bounded
			 * message to treating the JSON itself as an error string. */
			if (parsed && typeof parsed === 'object' && parsed.message)
				throw new Error(parsed.message);
			throw new Error((result.stderr || result.stdout || _('Command failed')).trim());
		}
		if (parsed == null)
			throw new Error(_('The APN helper returned invalid JSON'));
		return parsed;
	});
}

/* The channel a value that may not reach a command line takes.
 *
 * rpcd refuses `file exec` when a session-scoped caller passes an environment,
 * so the mechanism this project documented for an activation code and for the
 * manual-APN password does not exist. These three cross as ubus call
 * parameters instead -- neither a command line nor an environment -- and the
 * plugin behind them writes the value to the wrapper's standard input. The
 * answer that comes back is the wrapper's own, in the same shape `call()`
 * parses. */
var callApplyManual = rpc.declare({
	object: 'apn-autoconfig',
	method: 'apply_manual',
	params: [ 'target', 'apn', 'username', 'password', 'auth', 'ip_type' ],
	expect: {}
});

var callEsimDownload = rpc.declare({
	object: 'apn-autoconfig',
	method: 'esim_download',
	params: [ 'modem', 'endpoint', 'activation_code', 'confirmation_code',
		'matching_id', 'allow_unverified' ],
	expect: {}
});

var callEsimNickname = rpc.declare({
	object: 'apn-autoconfig',
	method: 'esim_nickname',
	params: [ 'modem', 'endpoint', 'profile', 'nickname' ],
	expect: {}
});

/* What a wrapper answered, from a reply that carries its exit code and its
 * output rather than being one. */
function secretResult(result) {
	var parsed = null;
	try {
		parsed = JSON.parse(result && result.stdout);
	}
	catch (e) {
		parsed = null;
	}
	if (parsed && typeof parsed === 'object' && parsed.incomplete === true)
		return parsed;
	if (!result || result.code !== 0)
		throw new Error((result && result.error) || _('The operation could not be started'));
	if (parsed == null)
		throw new Error(_('The APN helper returned invalid JSON'));
	return parsed;
}

/* A plan is a document on every path, including its refusals, and
 * `delete-plan` says so with a non-zero exit as well -- deliberately, so that a
 * script ignoring exit codes cannot read a refusal to plan as a plan. A caller
 * that threw on the exit code would turn every refusal into "the command
 * failed" and lose the reason. See docs/esim-contract-v1.md, "A refusal is a
 * document and a non-zero exit". */
function callPlan(command, args, env) {
	var request = env && Object.keys(env).length
		? fs.exec(command, args, env) : fs.exec(command, args);
	return request.then(function(result) {
		var parsed = null;
		try {
			parsed = JSON.parse(result.stdout);
		}
		catch (e) {
			parsed = null;
		}
		if (parsed && typeof parsed === 'object' && parsed.version)
			return parsed;
		if (result.code !== 0)
			throw new Error((result.stderr || result.stdout || _('Command failed')).trim());
		throw new Error(_('The APN helper returned invalid JSON'));
	});
}

/* A bounded duration in the unit a person experiences it in, from the plan's
 * own number and never from one this page chose. Below a minute and a half the
 * seconds are what a user recognises; above it, whole minutes rounded up,
 * because a ceiling rounded down is not a ceiling. */
function durationLabel(seconds) {
	var value = parseInt(seconds, 10);
	if (!(value > 0))
		return '';
	if (value < 90)
		return _('%s seconds').format(String(value));
	return _('%s minutes').format(String(Math.ceil(value / 60)));
}

/* The last four characters are the whole of what a display gets, and these
 * documents publish nothing else -- so there is no full value to reveal and no
 * reveal control belongs beside one. */
function suffixLabel(suffix) {
	var value = suffix == null ? '' : String(suffix);
	return value ? '\u2026' + value : '';
}

/* ---- gates (see docs/frontend-contract-v2.md, "Capability mapping") ----
 *
 * A capability field has three answers and never two. `true` permits, `false`
 * refuses with the backend's own reason, and **absent is unknown** — an older
 * backend that never published the field, which is a different situation from
 * a modem that cannot do the thing, and must not silence the control
 * permanently or read as permission. Everything that decides whether a control
 * exists goes through here, so `if (record.can_control_bearer)` — the shape
 * that turns absent into refused — cannot be written by accident. */
function gate(value) {
	if (value === true)
		return 'yes';
	if (value === false)
		return 'no';
	return 'unknown';
}

/* ---- result scope (see docs/convergence-contract-v1.md) ----
 *
 * Whether the last recorded verdict is about the modem and SIM that are here
 * now. A backend that does not publish the field is an older backend, and the
 * contract's standing rule applies: missing means unknown, never current. */
function resultState(status) {
	var state = status && status.result_state;
	if (state === 'current' || state === 'previous' || state === 'unknown')
		return state;
	return 'unknown';
}

/* Why a result is not about the present. Shown next to the verdict, because
 * "this is old" without "the SIM changed" leaves the user to guess which of
 * the two things they are looking at moved. */
function resultStaleReasonText(reason) {
	switch (reason) {
	case 'attachment-changed':
		return _('the modem has been disconnected and reconnected since');
	case 'sim-changed':
		return _('a different SIM is in the modem now');
	case 'sim-unknown':
		return _('the SIM it was about cannot be read at the moment');
	case 'attachment-unknown':
		return _('the modem it was about could not be confirmed just now');
	case 'no-scope':
		return _('it was recorded before this program kept track of what a result was about');
	}
	return '';
}

/* The names the engine gives the readings it abandoned, in the user's terms.
 * An unknown name is passed through rather than dropped: a reading nobody has
 * a phrase for is still a reading that is missing. */
function incompleteReadText(name) {
	switch (name) {
	case 'modem-list': return _('the list of modems');
	case 'modem-status': return _('the modem’s registration and signal');
	case 'sim-identity': return _('the SIM');
	case 'modem-resolve': return _('which modem belongs to this connection');
	case 'attachment': return _('whether the last result is still current');
	}
	return name;
}

function incompleteReads(status) {
	if (!status || status.incomplete !== true)
		return [];
	var reads = Array.isArray(status.incomplete_reads) ? status.incomplete_reads : [];
	return reads.map(incompleteReadText);
}

/* What the program was asked to do with the bearer, which is not what the
 * bearer is doing. A consumer that cannot find the field reads `auto`, as the
 * convergence contract requires. */
function bearerIntent(status) {
	var value = status && status.desired_bearer_state;
	return value === 'up' || value === 'down' ? value : 'auto';
}

/* The provisioning verdict travels with the inventory record itself.
 *
 * It used to be a provision-plan call per modem, which meant one helper process
 * and one full hardware scan for each — so a page load paid the scan 1+N times
 * and took seconds, with none of it spent waiting on the modems. The fields are
 * additive and carry the same names and meanings the separate call returned, so
 * this reshapes a record rather than changing what any of it means. */
function planOf(modem) {
	if (!modem || typeof modem !== 'object')
		return { error: 'no record' };
	/* A record without the verdict is not a modem that cannot be provisioned —
	 * it is an answer we did not get, and the two must not read the same. This
	 * is what an older backend, or a truncated response, looks like from here. */
	if (modem.provision_reason == null && modem.can_provision == null)
		return { error: 'no provisioning verdict in the inventory record' };
	return {
		can_provision: modem.can_provision,
		reason: modem.provision_reason,
		section: modem.provision_section,
		existing_section: modem.provision_existing_section,
		protocol: modem.provision_protocol,
		netifd_restart_required: modem.netifd_restart_required,
		can_control_bearer: modem.can_control_bearer,
		connection_section: modem.connection_section,
		connection_owned: modem.connection_owned,
		/* Who owns the settings of the section this modem is bound to, which
		 * is a different question from who may start and stop it. It travels
		 * with the same record for the same reason the provisioning verdict
		 * does: `adopt-plan` is a read of its own and a page that asked one per
		 * modem would pay a scan per modem to draw a sentence. */
		connection_origin: modem.connection_origin,
		can_adopt: modem.can_adopt,
		adoption_reason: modem.adoption_reason,
		adoption_section: modem.adoption_section,
		can_release_adoption: modem.can_release_adoption
	};
}

function text(value) {
	return value == null || value === '' ? '—' : String(value);
}

function valueNode(value) {
	return value != null && typeof value === 'object' ? value : text(value);
}

function maskedIdentifier(value) {
	var identifier = value == null ? '' : String(value);
	if (!identifier)
		return '—';
	var visible = identifier.length > 4 ? identifier.slice(-4) : '';
	return new Array(identifier.length - visible.length + 1).join('•') + visible;
}

/* Masked to the last four characters, revealed one value at a time on
 * activation, and re-masked whenever the page is re-rendered — which is what
 * navigation and every poll do, so a reveal is never persisted. */
function sensitiveIdentifier(value, label) {
	var identifier = value == null ? '' : String(value);
	if (!identifier)
		return text(value);

	var revealed = false;
	/* No fixed character width and no nowrap. A modem identity is long enough
	 * to push its own reveal control off a 390 px screen, which is a control
	 * the user cannot reach — and the masked and revealed forms are the same
	 * length anyway, so nothing here needs reserved space to stop it jumping. */
	var display = E('span', {
		'class': 'apn-sensitive-value',
		'style': 'display:inline-block;max-width:100%;font-family:monospace;overflow-wrap:anywhere'
	}, [ maskedIdentifier(identifier) ]);
	var showLabel = E('span', { 'class': 'apn-sensitive-show-label', 'aria-hidden': 'true' }, [ _('Show') ]);
	var hideLabel = E('span', { 'class': 'apn-sensitive-hide-label', 'aria-hidden': 'true' }, [ _('Hide') ]);
	showLabel.style.gridArea = '1 / 1';
	hideLabel.style.gridArea = '1 / 1';
	showLabel.style.visibility = 'visible';
	hideLabel.style.visibility = 'hidden';
	var button = E('button', {
		'class': 'btn cbi-button cbi-button-neutral apn-sensitive-toggle',
		'type': 'button',
		'data-apn-control': 'reveal',
		'style': 'display:inline-grid',
		'title': _('Show full %s').format(label),
		'aria-label': _('Show full %s').format(label),
		'click': function(ev) {
			ev.preventDefault();
			revealed = !revealed;
			dom.content(display, [ revealed ? identifier : maskedIdentifier(identifier) ]);
			showLabel.style.visibility = revealed ? 'hidden' : 'visible';
			hideLabel.style.visibility = revealed ? 'visible' : 'hidden';
			button.setAttribute('title', revealed ? _('Hide %s').format(label) : _('Show full %s').format(label));
			button.setAttribute('aria-label', revealed ? _('Hide %s').format(label) : _('Show full %s').format(label));
		}
	}, [ showLabel, hideLabel ]);

	return E('span', {
		'class': 'apn-sensitive-identifier',
		'style': 'display:inline-flex;flex-wrap:wrap;align-items:center;gap:.5em;max-width:100%'
	}, [ display, button ]);
}

/* Help opens on activation, never on hover: a hover tooltip is unreachable on
 * a touch screen, and touch screens are how many people administer a router.
 * The text is created when it is asked for rather than hidden with CSS, so
 * "not shown" and "not there" are the same state.
 *
 * The toggle is marked as navigation rather than given a catalogue id: it
 * reveals text that is already on the page and reaches no wrapper. The suites
 * hold that claim to account by asserting that no node marked this way ever
 * issues a call. */
function helpfulLabel(label, help) {
	if (!help)
		return E('strong', {}, [ label ]);

	var body = E('div', { 'class': 'apn-help-body' }, []);
	var opened = false;
	var button = E('button', {
		'class': 'btn cbi-button cbi-button-neutral apn-help-toggle',
		'type': 'button',
		'data-apn-nav': 'help',
		'aria-expanded': 'false',
		'title': _('What does “%s” mean?').format(label),
		'aria-label': _('What does “%s” mean?').format(label),
		'click': function(ev) {
			ev.preventDefault();
			opened = !opened;
			dom.content(body, opened ? [ E('p', { 'class': 'apn-help-text' }, [ help ]) ] : []);
			button.setAttribute('aria-expanded', opened ? 'true' : 'false');
		}
	}, [ '?' ]);

	return E('div', { 'class': 'apn-help' }, [
		E('span', { 'class': 'apn-help-label' }, [ E('strong', {}, [ label ]), button ]),
		body
	]);
}

function row(label, value, help) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left apn-label', 'style': 'width:40%' }, [ helpfulLabel(label, help) ]),
		E('td', { 'class': 'td left apn-value' }, [ valueNode(value) ])
	]);
}

function table(rows) {
	return E('table', { 'class': 'table apn-table' }, rows);
}

/* Evidence-grade fields stay truthful and stay available; they simply stop
 * being the first thing a person reads. Closed by default, every time. */
function advanced(rows) {
	return E('details', { 'class': 'apn-details apn-advanced' }, [
		E('summary', {}, [ _('Advanced and diagnostic details') ]),
		table(rows)
	]);
}

/* A capability an accepted contract defines and a milestone owns, which no
 * shipped backend publishes yet. It is text and never a control: a greyed
 * button is how this page says "an operation is running", and a user who
 * cannot tell the two apart cannot tell whether to wait. At most one of these
 * per area. */
function plannedLine(id, message) {
	return E('p', { 'class': 'apn-planned', 'data-apn-planned': id }, [ message ]);
}

/* The answer could not be obtained. Deliberately not the refusal sentence: an
 * older backend and a modem that cannot do something are different situations,
 * and only one of them should silence a control permanently. */
function unknownLine(what, next) {
	return E('p', { 'class': 'apn-unknown-line' }, [
		next ? '%s %s'.format(_('%s could not be determined.').format(what), next)
			: _('%s could not be determined.').format(what)
	]);
}

/* The backend refused, and the reason is the backend's own field. Never
 * "unavailable": the composition that cannot do this is named. */
function refusalLine(message) {
	return E('p', { 'class': 'apn-refusal-line' }, [ message ]);
}

/* The fourth presentation, and the one a rebuild loses first. A fact that has
 * been asked for and has not answered yet is *not* `unknown`: that sentence
 * says the read was attempted and failed, and it offers to try again, which is
 * wrong twice over while the read is still in flight. It draws no control, for
 * the same reason `unknown` draws none -- and in particular no disabled
 * control, because a greyed control still means an operation is running and
 * nothing else. It must resolve into known, refused or unknown within the
 * read's own bound; a `pending` that never resolves is a defect, not a state. */
function pendingLine(what) {
	return E('p', { 'class': 'apn-pending-line', 'data-apn-pending': '1' }, [
		_('Reading %s…').format(what)
	]);
}

function networkLabel(name, id) {
	if (name && id)
		return '%s (%s)'.format(name, id);
	return name || id || '';
}

function simProviderLabel(status) {
	if (status && status.operator_name)
		return status.operator_name;
	return status && status.registration_state === 'home' ? status.serving_operator_name : '';
}

function homeNetworkLabel(status) {
	if (!status)
		return '';
	if (status.home_operator_name || status.home_operator_id)
		return networkLabel(status.home_operator_name, status.home_operator_id);
	if (status.registration_state === 'home')
		return networkLabel(status.serving_operator_name, status.serving_operator_id);
	return '';
}

function formatTimestamp(value) {
	if (!value)
		return '';
	var date = new Date(value);
	return isNaN(date.getTime()) ? value : date.toLocaleString();
}

function databaseReleaseDate(version) {
	return /^\d{4}\.\d{2}\.\d{2}$/.test(version || '') ? version.replace(/\./g, '-') : '';
}

function signalPercent(value) {
	if (value == null || value === '')
		return null;
	var percent = parseInt(value, 10);
	if (isNaN(percent))
		return null;
	return Math.max(0, Math.min(100, percent));
}

function signalQuality(value) {
	var percent = signalPercent(value);
	if (percent == null)
		return text(value);
	return E('div', { 'class': 'cbi-progressbar', 'title': '%s%%'.format(percent) }, [
		E('div', { 'style': 'width:%s%%'.format(percent) }, [])
	]);
}

function roamingPolicyLabel(status) {
	switch (status && status.roaming_policy) {
	case 'explicit-allow': return _('Explicitly allowed');
	case 'explicit-block': return _('Explicitly blocked');
	case 'default-allow': return _('Allowed by the OpenWrt default');
	/* The absent default is backend-specific: OpenWrt's MBIM handler refuses
	 * roaming when neither option is set, where ModemManager allows it. */
	case 'default-block': return _('Blocked by the OpenWrt default');
	case 'invalid': return _('Custom configuration this page will not change');
	default: return _('Unknown');
	}
}

function policyValue(status) {
	switch (status && status.roaming_policy) {
	case 'explicit-allow': return 'allow';
	case 'explicit-block': return 'block';
	/* A custom option pair cannot be represented by any of the three policies.
	 * Showing "default" would invite an accidental normalization of something
	 * somebody configured deliberately. */
	case 'invalid': return 'custom';
	default: return 'default';
	}
}

function defaultPolicyOptionLabel(status) {
	if (status && status.target_backend === 'mbim')
		return _('OpenWrt default (blocked)');
	return _('OpenWrt default (allowed)');
}

/* The three answers, for a capability that lives on the status document's
 * target_capabilities map. v1 had two compatibility inferences here — an
 * absent map kept the ModemManager controls a 0.9.0 upgrade used to have, and
 * an absent `roaming_policy_write` was inferred from the backend's name. Both
 * spell an absent field as an answer, which is precisely what v2 forbids: an
 * older backend and a target that cannot do something are different
 * situations, and only one of them should silence a control permanently. So
 * neither survives, and the page says it does not know instead. */
function targetGate(status, name) {
	if (!status || status.error || !status.target_capabilities)
		return 'unknown';
	return gate(status.target_capabilities[name]);
}

function roamingPolicyGate(status) {
	if (!status || status.error || status.version !== 'v2')
		return 'unknown';
	return targetGate(status, 'roaming_policy_write');
}

function roamingPolicyDescription(status) {
	var target = status && status.interface || 'wwan';
	if (status && status.target_backend === 'mbim')
		return _('This edits the canonical network.%s.allow_roaming and allow_partner options used by netifd. Both are needed: OpenWrt refuses roaming and partner networks when they are unset, and APN profiles never change them automatically.').format(target);
	return _('This edits the canonical network.%s.allow_roaming option used by netifd and ModemManager. APN profiles never change it automatically.').format(target);
}

function roamingPolicyRefusal(status) {
	var backend = status && status.target_backend || _('unknown');
	return _('Roaming policy control is unavailable for the %s backend this connection uses. This program manages only APN profiles; configure roaming in the package or interface that manages this connection.').format(backend);
}

function roamingPolicyCustom(status) {
	return !!(status && status.roaming_policy === 'invalid');
}

function trustLabel(value, positive, negative) {
	return E('span', { 'class': value ? 'apn-state-good' : 'apn-state-bad' }, [ value ? positive : negative ]);
}

function registrationLabel(status) {
	if (!status || status.error)
		return _('unknown');
	if (status.roaming === true)
		return _('%s (roaming)').format(status.registration_state || _('registered'));
	return status.registration_state || _('unknown');
}

/* The browser objects the page touches, reached defensively so the view can be
 * evaluated outside a browser. Nothing here ever carries a secret: the address
 * holds a modem_id or a section name, both of which already appear in the argv
 * of every action, and an EID, ICCID or IMSI never reaches it. */
/* What somebody pasted, turned into an activation code -- or a reason it is
 * not one.
 *
 * A person is not required to know what an activation code is, what SGP.22
 * says about it, or which parts of it matter. They copy what their provider
 * gave them, and providers do not agree on the shape: opencode's site copies
 * `LPA:1$host$id`, a QR scanner may hand over the same thing without the
 * `LPA:` prefix, and a person retyping from a letter adds spaces. All of those
 * are the same code and all of them are accepted.
 *
 * The refusals are the other half, and they exist because a bad code is not
 * free: reaching the card means taking the modem from its owner, and on the
 * reference hardware that is a real outage. Something that cannot possibly be
 * a code is refused here, in the browser, before anything is opened.
 *
 * Nothing in the returned reason quotes what was typed. An activation code is
 * worth the subscription it buys, and an error message is the easiest place
 * for one to end up in a screenshot. */
function activationCode(raw) {
	var text = String(raw == null ? '' : raw).replace(/\s+/g, '');
	if (!text)
		return { ok: false, why: _('Enter the activation code your provider gave you.') };
	/* The prefix is part of the code and optional in practice. Case-insensitive
	 * because it is written both ways in the wild. */
	var body = text.replace(/^LPA:/i, '');
	var parts = body.split('$');
	/* `1` is the only format version SGP.22 has ever defined. A string that
	 * does not start with it is not an activation code, whatever else it is. */
	if (parts.length < 3 || parts[0] !== '1')
		return { ok: false, why: _('That does not look like an activation code. It should look like LPA:1$… — paste the whole thing exactly as your provider gave it, including any part before or after the dollar signs.') };
	var host = parts[1];
	/* A hostname and nothing else: no scheme, no path, no credentials. This is
	 * the address the router will open a TLS connection to, and a value that
	 * is not a hostname cannot be one that was meant. */
	if (!host || host.length > 255 || !/^[A-Za-z0-9.-]+$/.test(host)
		|| host.indexOf('.') === -1 || host.charAt(0) === '.'
		|| host.charAt(host.length - 1) === '.')
		return { ok: false, why: _('The provider address inside that code is not a valid address, so nothing was contacted.') };
	var matching = parts[2];
	if (!matching || matching.length > 128 || !/^[A-Za-z0-9-]+$/.test(matching))
		return { ok: false, why: _('The subscription reference inside that code is not one this router can use, so nothing was contacted.') };
	if (body.length > 1024)
		return { ok: false, why: _('That is too long to be an activation code, so nothing was contacted.') };
	/* Handed on in the one shape this project has hardware evidence for. */
	return { ok: true, code: 'LPA:' + body };
}

/* The provider address out of a code that has already passed the check above,
 * which is the one part of it safe to show back. It says which subscription
 * was read without repeating the thing that buys it. */
function activationCodeHost(code) {
	var parts = String(code || '').replace(/^LPA:/i, '').split('$');
	return parts.length > 1 ? parts[1] : '';
}

/* Where this package installed the decoder. LuCI's resource base is
 * configurable, so it is asked for when it can be; the literal is the
 * documented default and the only other thing it is ever set to. */
function qrDecoderUrl() {
	if (typeof L !== 'undefined' && L && typeof L.resource === 'function')
		return L.resource('apn-autoconfig/jsQR.js');
	return '/luci-static/resources/apn-autoconfig/jsQR.js';
}

function browserWindow() {
	return typeof window !== 'undefined' && window ? window : null;
}

/* Every node under `node`, in document order. Written against `.children`
 * rather than a DOM query so that the same walk works on a real element and on
 * the node tree the fixtures build — which is what lets the focus rule below
 * be asserted rather than described. */
function walkNodes(node, visit) {
	if (!node || typeof node !== 'object')
		return;
	visit(node);
	var children = node.children;
	if (!children || typeof children.length !== 'number')
		return;
	for (var index = 0; index < children.length; index++)
		walkNodes(children[index], visit);
}

/* What a control *is*, independently of the node currently drawing it. A
 * re-render replaces the node; this survives it, so the keyboard can be put
 * back on the control it was on rather than on the top of the page. */
function focusKeyOf(node) {
	if (!node || typeof node.getAttribute !== 'function')
		return null;
	var control = node.getAttribute('data-apn-control');
	var nav = node.getAttribute('data-apn-nav');
	if (!control && !nav)
		return null;
	return [ control || '', nav || '', node.getAttribute('data-apn-area') || '' ].join('\u0001');
}

function focusableNodes(root) {
	var found = [];
	walkNodes(root, function(node) {
		if (focusKeyOf(node))
			found.push(node);
	});
	return found;
}

var workspaceAreas = [ 'connection', 'sim', 'esim', 'apn', 'modem', 'diagnostics' ];
var routerAreas = [ 'overview', 'database', 'settings' ];

return view.extend({
	/* ---- loading ------------------------------------------------------- */

	/* The document set is read in levels, and the page pays for a level only
	 * when the user has reached the part of it that needs one. The whole set
	 * costs about 6.6 s on the reference router and the page used to block its
	 * first paint on all of it -- for a user who came to change a setting as
	 * much as for one who came to look at a modem.
	 *
	 * Level 0 is the router-scoped reads plus the modem inventory, about 1.2 s
	 * and issued in parallel. It is what decides which cards exist, so the
	 * cards are complete and keep their identity from the moment they appear.
	 * Level 1 is one status per target -- 1.3 s and 3.2 s here -- and each card
	 * completes on its own answer instead of on the slowest one. Level 2 is the
	 * eSIM inventory and is not read until the SIM or the eSIM area is opened.
	 *
	 * See docs/work-items/P7-the-page-a-user-waits-for.md for the measurements
	 * this shape comes from. */
	emptyDocuments: function() {
		return {
			targets: null, statuses: {}, action: null, database: null, inventory: null,
			routerRead: false, statusRead: {},
			/* Level 2 and level 3, kept apart on purpose. `esim` is the slot
			 * and endpoint inventory, which opens no channel to a card;
			 * `esimCard` is what a read of the card itself produced, and
			 * nothing puts anything in it except a control somebody pressed. */
			esim: {}, esimRead: {}, esimCard: {}, esimAction: {}
		};
	},

	/* Level 0. Nothing here waits for anything else here: the inventory does
	 * not depend on the target list, and issuing it after one was pure serial
	 * cost. */
	/* Read one after another, on purpose, and measured on the reference router
	 * rather than assumed.
	 *
	 * `Promise.all` is the idiom that looks like parallelism, and here it is
	 * strictly worse than a queue. LuCI's rpc path serialises these calls
	 * whatever the page does -- two status reads issued together take the *sum*
	 * of their durations, not the larger of them -- and it resolves them all at
	 * the same instant when the last one lands. So the concurrency is imaginary
	 * and the cost of pretending is real: every answer is withheld until the
	 * slowest arrives.
	 *
	 * Measured with one fast target and one slow one: issued together, both
	 * answers arrive at 4442 ms; issued in sequence, the first arrives at
	 * 1115 ms and the last at 4424 ms. The same total, and one card drawn three
	 * and a half seconds earlier.
	 *
	 * Order is therefore a design decision. The two documents that decide which
	 * cards exist come first; the cheap operation state next, because it is what
	 * a control is greyed by; and the provider database last, because only its
	 * own area reads it. */
	sequence: function(steps) {
		return steps.reduce(function(chain, step) {
			return chain.then(step);
		}, Promise.resolve());
	},

	loadRouterDocuments: function() {
		var self = this;
		var documents = { targets: null, action: null, database: null, inventory: null };
		var read = function(command, args) {
			return call(command, args).catch(function(error) { return { error: error.message }; });
		};

		return self.sequence([
			function() {
				return read(queryCommand, [ 'targets' ])
					.then(function(value) { documents.targets = value; });
			},
			function() {
				return read(modemQueryCommand, [ 'inventory' ]).then(function(inventory) {
					documents.inventory = inventory;
					var modems = inventory && Array.isArray(inventory.modems) ? inventory.modems : [];
					/* The plan arrives with the record. Only the operation state
					 * still needs a call of its own, because it is a coordinator
					 * fact rather than an inventory one -- and these queue behind
					 * each other like everything else. */
					return self.sequence(modems.map(function(modem) {
						return function() {
							modem.plan = planOf(modem);
							return read(modemQueryCommand, [ 'action-status', modem.modem_id ])
								.then(function(operation) { modem.operation = operation; });
						};
					}));
				});
			},
			function() {
				return read(queryCommand, [ 'action-status' ])
					.then(function(value) { documents.action = value; });
			},
			function() {
				return read(queryCommand, [ 'database-status' ])
					.then(function(value) { documents.database = value; });
			}
		]).then(function() { return documents; });
	},

	targetIds: function(documents) {
		var targets = documents && documents.targets;
		if (!targets || targets.error || !Array.isArray(targets.targets))
			return [];
		return targets.targets.map(function(target) { return target.id; });
	},

	/* Level 1, one target. Separate so that a card can be completed on its own
	 * answer; the AT-dial target costs three times what the ModemManager one
	 * does, and there is no reason for the cheap card to wait on it. */
	loadTargetStatus: function(id) {
		return call(queryCommand, [ 'status', id ])
			.catch(function(error) { return { error: error.message }; });
	},

	/* The whole set, for the refresh path: the page is already on screen, so
	 * there is nothing to stage against. Levels 0 and 1 still overlap. */
	loadDocuments: function() {
		var self = this;
		return self.loadRouterDocuments().then(function(base) {
			var ids = self.targetIds(base);
			var entries = [];
			return self.sequence(ids.map(function(id) {
				return function() {
					return self.loadTargetStatus(id).then(function(status) {
						entries.push({ id: id, status: status });
					});
				};
			})).then(function() {
				var statuses = {};
				var statusRead = {};
				entries.forEach(function(entry) {
					statuses[entry.id] = entry.status;
					statusRead[entry.id] = true;
				});
				return {
					targets: base.targets, statuses: statuses, action: base.action,
					database: base.database, inventory: base.inventory,
					routerRead: true, statusRead: statusRead,
					esim: self.documents ? self.documents.esim : {},
					esimRead: self.documents ? self.documents.esimRead : {},
					esimCard: self.documents ? self.documents.esimCard : {},
					esimAction: self.documents ? self.documents.esimAction : {}
				};
			});
		});
	},

	/* Nothing a modem has to answer is read here. The page appears, its areas
	 * are navigable, and Program settings -- which a user may well have come
	 * for and which needs no modem at all -- is usable while the reads that
	 * belong to the other areas are still in flight. */
	load: function() {
		return Promise.all([ uci.load('apn-autoconfig') ]);
	},

	/* ---- the objects on the page ---------------------------------------- */

	/* One card per card subject, and the subject is decided by what was
	 * actually observed rather than by pairing something with something else.
	 * A card is never keyed by the pair, because pairing is an observation
	 * that can fail and a page whose primary object disappears when one read
	 * is inconclusive is a page that hides a modem to protect a layout. */
	buildSubjects: function(documents) {
		var self = this;
		var inventory = documents.inventory;
		var targets = documents.targets;
		var modems = inventory && !inventory.error && Array.isArray(inventory.modems)
			? inventory.modems : [];
		var targetList = targets && !targets.error && Array.isArray(targets.targets)
			? targets.targets : [];
		var targetById = {};
		targetList.forEach(function(target) { targetById[target.id] = target; });

		var claimed = {};
		var subjects = modems.map(function(modem) {
			var plan = modem.plan || planOf(modem);
			var section = modem.netifd_interface || plan.connection_section || '';
			/* An ambiguous modem's binding is not proven, so it does not claim
			 * the section. The connection then becomes a card of its own — a
			 * connection with unknown hardware — rather than a row inside the
			 * card of the modem it probably belongs to. */
			if (section && modem.ambiguous !== true)
				claimed[section] = true;
			var id = section ? 'network:' + section : '';
			return {
				key: 'modem:' + modem.modem_id,
				kind: 'modem',
				modem: modem,
				plan: plan,
				section: modem.ambiguous === true ? '' : section,
				targetId: modem.ambiguous === true ? '' : id,
				target: id ? targetById[id] : null,
				status: id && modem.ambiguous !== true ? documents.statuses[id] : null,
				operation: modem.operation,
				ambiguous: modem.ambiguous === true,
				name: self.modemModelLabel(modem)
			};
		});

		targetList.forEach(function(target) {
			if (claimed[target.interface])
				return;
			subjects.push({
				key: 'target:' + target.interface,
				kind: 'target',
				modem: null,
				plan: {},
				section: target.interface,
				targetId: target.id,
				target: target,
				status: documents.statuses[target.id],
				operation: null,
				ambiguous: false,
				name: target.interface
			});
		});

		return subjects;
	},

	subjectByKey: function(key) {
		var found = (this.subjects || []).filter(function(subject) { return subject.key === key; });
		return found.length === 1 ? found[0] : null;
	},

	managedTargets: function() {
		var targets = this.documents && this.documents.targets;
		if (!targets || targets.error || !Array.isArray(targets.targets))
			return [];
		return targets.targets.filter(function(target) { return target.managed === true; });
	},

	/* The modem's own name for itself, read over AT. It is display evidence,
	 * not identity — two identical modems say exactly the same thing — so it
	 * never replaces the identifier under the advanced disclosure. */
	modemModelLabel: function(modem) {
		if (modem.manufacturer && modem.model)
			return '%s %s'.format(modem.manufacturer, modem.model);
		if (modem.model)
			return modem.model;
		if (modem.vendor_id && modem.product_id)
			return _('Cellular modem %s:%s').format(modem.vendor_id, modem.product_id);
		return _('Unidentified modem');
	},

	subjectHeading: function(subject) {
		if (subject.kind === 'target')
			return subject.section;
		if (subject.ambiguous)
			return subject.modem.usb_path
				? '%s · %s'.format(subject.name, subject.modem.usb_path) : subject.name;
		return subject.section ? '%s · %s'.format(subject.name, subject.section) : subject.name;
	},

	/* ---- connection-control semantics ----------------------------------- */

	/* One table, one place. The inputs are the observed bearer state, the
	 * recorded intention, whether an operation is running and whether the
	 * bearer may be controlled at all — and the two rows that must never
	 * converge are `down`+`down`, which nobody should call a failure, and
	 * `down`+`up`, which is the only one of the two that is one. */
	connectionState: function(subject) {
		var status = subject.status;
		var plan = subject.plan || {};

		if (subject.ambiguous)
			return {
				key: 'ambiguous', label: _('Cannot be identified separately from another modem'),
				tone: 'neutral', primary: null, secondary: [],
				note: _('This modem could not be told apart from another one on this router. No action is offered for either of them.')
			};

		if (subject.kind === 'modem' && plan.error)
			return {
				key: 'plan-unknown', label: _('Not known'), tone: 'neutral',
				primary: null, secondary: [],
				unknown: _('Whether this modem can be set up or controlled')
			};

		if (subject.kind === 'modem' && gate(plan.can_provision) === 'yes')
			return {
				key: 'unprovisioned', label: _('Supported, not set up yet'), tone: 'neutral',
				primary: 'provision', secondary: [],
				note: _('A network interface has not been created for this modem yet.')
			};

		if (subject.kind === 'target' && !subject.modem)
			return {
				key: 'hardware-absent', label: _('Hardware not present'), tone: 'neutral',
				primary: null, secondary: [],
				note: _('The modem this connection was set up for is not attached. Its settings are kept. Nothing is being retried.')
			};

		var bearer = subject.kind === 'modem' ? gate(plan.can_control_bearer)
			: targetGate(status, 'profile_apply');
		if (subject.kind === 'modem' && bearer === 'unknown')
			return {
				key: 'bearer-unknown', label: this.observedBearerLabel(status), tone: 'neutral',
				primary: null, secondary: [],
				unknown: _('Whether the connection can be controlled from here'),
				unknownNext: _('The installed version of this program does not report it. Updating the packages would answer it.')
			};
		if (bearer === 'no')
			return {
				key: 'bearer-refused', label: this.observedBearerLabel(status), tone: 'neutral',
				primary: null, secondary: [],
				refusal: this.bearerRefusalText(subject)
			};

		var up = !!(status && status.interface_up);
		var intent = bearerIntent(status);

		if (up && (intent === 'auto' || intent === 'up'))
			return {
				key: 'connected', label: _('Connected'), tone: 'good',
				primary: 'disconnect', secondary: [ 'reconnect' ]
			};
		if (up)
			return {
				key: 'connected-unwanted', label: _('Connected — not by this program'),
				tone: 'neutral', primary: 'disconnect', secondary: [],
				note: _('This program was asked to leave this connection down and did not bring it up.')
			};
		if (intent === 'up')
			return {
				key: 'failed', label: _('Not connected — the last attempt did not hold'),
				tone: 'bad', primary: 'reconnect', secondary: [ 'disconnect' ],
				note: _('Disconnect stops this program trying to bring the interface up.')
			};
		if (intent === 'down')
			return {
				key: 'switched-off', label: _('Switched off here'), tone: 'neutral',
				primary: 'connect', secondary: [],
				note: _('This connection is down because it was stopped here, not because anything failed.')
			};
		return {
			key: 'not-connected', label: _('Not connected'), tone: 'neutral',
			primary: 'connect', secondary: []
		};
	},

	/* What is happening to this modem right now, named with its verb and its
	 * stage, or nothing when nothing is. This is layered on top of the
	 * connection state rather than replacing it: the state still decides which
	 * controls exist, and running decides only that they are disabled. */
	subjectOperationText: function(subject) {
		var operation = subject && subject.operation;
		if (!operation || operation.error || !operation.busy)
			return '';
		var stage = this.operationStageText(operation);
		return stage ? '%s — %s'.format(this.actionLabel(operation.action), stage)
			: this.operationLabel(operation);
	},

	observedBearerLabel: function(status) {
		return status && status.interface_up ? _('Connected') : _('Not connected');
	},

	bearerRefusalText: function(subject) {
		var plan = subject.plan || {};
		if (subject.kind === 'modem')
			return this.provisionReasonText(plan.reason, subject.modem);
		return _('This connection’s backend cannot be started or stopped from here.');
	},

	/* Why a modem cannot be set up, in the user's terms, and always from the
	 * backend's own reason. A missing control is always explained; the page
	 * never shows a button that is going to fail. */
	provisionReasonText: function(reason, modem) {
		switch (reason) {
		case 'already_configured':
			/* The full sentence, and the action it implies, are in the
			 * Connection area under "Who looks after these settings". This
			 * answers the narrower question this area asks -- whether a new
			 * interface would be created -- and points at the other. */
			return _('A network interface you created is already bound to this modem, so this program does not create another one. Who looks after its settings is under Connection.');
		case 'already_provisioned':
			return _('This modem is set up by this program.');
		case 'ambiguous':
			return _('This modem could not be told apart from another one, so nothing will be changed automatically.');
		case 'unsupported_protocol':
			/* An AT-managed modem is recognised and its SIM can be read, but
			 * nothing installed can dial it yet. Saying so is more useful than
			 * the generic protocol message, because the missing piece is a
			 * package rather than anything about this device. */
			if (modem && modem.protocol === 'at')
				return _('This modem is recognised and its SIM can be read, but no connection support for it is installed yet, so it cannot be set up here.');
			return _('Setting up this modem automatically is not supported yet for its control protocol.');
		case 'conflicting_owner':
			return _('Another component is claiming control of this modem, so it is left alone.');
		case 'no_device':
			return _('No usable control device was found for this modem.');
		}
		return _('This modem cannot be set up automatically right now.');
	},

	/* ---- the verdict slot ------------------------------------------------ */

	/* `current` is the only state that may occupy it. The two demoted states
	 * are labelled differently and rendered differently from each other and
	 * from an error: a previous result is settled and merely old, an
	 * unconfirmed one is a question. */
	verdictNode: function(subject) {
		var status = subject.status;
		if (!status || status.error)
			return null;
		var state = resultState(status);
		if (state === 'current') {
			if (!status.last_result)
				return E('div', { 'class': 'apn-verdict apn-verdict-none' }, [ _('Nothing recorded yet') ]);
			var failed = status.result_code && status.result_code !== 'success';
			return E('div', { 'class': 'apn-verdict apn-verdict-current' + (failed ? ' apn-tone-bad' : '') },
				[ status.last_result ]);
		}
		if (state === 'previous')
			return E('div', { 'class': 'apn-verdict apn-verdict-previous' },
				[ _('Last check was for a different SIM or a different attachment') ]);
		return E('div', { 'class': 'apn-verdict apn-verdict-unknown' },
			[ _('Not checked yet for this SIM') ]);
	},

	/* ---- controls -------------------------------------------------------- */

	/* Every control is created here, so every control node carries its
	 * catalogue id and every control is registered for the one thing a
	 * disabled control is allowed to mean. */
	control: function(id, label, cssClass, onActivate, options) {
		var self = this;
		options = options || {};
		var button = E('button', {
			'class': 'btn cbi-button ' + cssClass,
			'type': 'button',
			'data-apn-control': id,
			'click': function(ev) {
				ev.preventDefault();
				if (button.disabled)
					return;
				onActivate();
			}
		}, [ label ]);
		if (options.busy)
			button.disabled = true;
		self.controls.push(button);
		return button;
	},

	/* Whether an operation that would take the locks this control needs is
	 * already running. It is the only reason a control is ever disabled. */
	subjectBusy: function(subject) {
		if (this.engineBusy)
			return true;
		if (subject && subject.operation && !subject.operation.error && subject.operation.busy)
			return true;
		/* An eSIM operation holds the same modem's locks, so everything about
		 * that modem is busy while it runs -- including the controls of the
		 * other areas, which would otherwise offer an operation that is going
		 * to be refused for the whole of a four-minute takeover. */
		var esim = this.esimOperationFor && subject ? this.esimOperationFor(subject) : null;
		return !!(esim && !esim.error && esim.busy);
	},

	anySubjectBusy: function() {
		var self = this;
		if (self.engineBusy)
			return true;
		return (self.subjects || []).some(function(subject) {
			return self.subjectBusy(subject);
		});
	},

	bearerControl: function(subject, verb, label, cssClass) {
		var self = this;
		var ids = { connect: 'connect', disconnect: 'disconnect', reconnect: 'reconnect',
			provision: 'provision', deprovision: 'deprovision' };
		return self.control(ids[verb], label, cssClass, function() {
			self.confirmModemAction(subject, verb);
		}, { busy: self.subjectBusy(subject) });
	},

	bearerControlLabel: function(verb) {
		switch (verb) {
		case 'connect': return _('Connect');
		case 'disconnect': return _('Disconnect');
		case 'reconnect': return _('Reconnect');
		case 'provision': return _('Set up connection');
		case 'deprovision': return _('Remove setup');
		}
		return verb;
	},

	bearerControlClass: function(verb, primary) {
		if (verb === 'disconnect' || verb === 'deprovision')
			return primary ? 'cbi-button-remove important' : 'cbi-button-neutral';
		return primary ? 'cbi-button-action important' : 'cbi-button-neutral';
	},

	/* Re-check one connection. Always the target of that connection, never the
	 * engine's own first choice. */
	reconcileOneControl: function(subject) {
		var self = this;
		return self.control('reconcile-one', _('Re-check this connection'), 'cbi-button-action', function() {
			self.confirmEngineAction('reconcile', subject.targetId, _('Re-check this connection'),
				_('This verifies the current SIM, APN and real Internet access. If necessary, it changes the APN and restarts only this mobile interface.'),
				_('This runs against %s only.').format(subject.section));
		}, { busy: self.subjectBusy(subject) });
	},

	checkNowControl: function(subject) {
		var self = this;
		return self.control('reconcile-one', _('Check now'), 'cbi-button-neutral', function() {
			self.confirmEngineAction('reconcile', subject.targetId, _('Check now'),
				_('This verifies the current SIM, APN and real Internet access. If necessary, it changes the APN and restarts only this mobile interface.'),
				_('This runs against %s only.').format(subject.section));
		}, { busy: self.subjectBusy(subject) });
	},

	/* The fan-out v1's "Automatic — all managed targets" display mode
	 * performed, stated as an action instead of implied by a display mode. It
	 * runs against every managed target, which is what the engine does with no
	 * target argument, and the confirmation names exactly that set. */
	reconcileAllControl: function() {
		var self = this;
		var managed = self.managedTargets();
		return self.control('reconcile-all', _('Re-check every managed target'), 'cbi-button-action', function() {
			self.confirmEngineAction('reconcile', null, _('Re-check every managed target'),
				_('This verifies the current SIM, APN and real Internet access on every connection this program looks after. If necessary, it changes an APN and restarts only that mobile interface.'),
				_('This runs against every managed target: %s.').format(managed.map(function(target) {
					return target.interface;
				}).join(', ')));
		}, { busy: self.anySubjectBusy() });
	},

	/* The power-cycle keeps running through the engine command the hardware
	 * button already uses, so the validated reset-then-reconcile behaviour is
	 * unchanged. It names this modem's own interface: without one the engine
	 * would resolve whichever target it manages first, and on a router with
	 * two modems that means one modem's workspace power-cycling the other. */
	resetControl: function(subject) {
		var self = this;
		var label = subject.modem && subject.modem.reset_method === 'gpio'
			? _('Power-cycle this modem') : _('Restart this modem');
		return self.control('modem-reset', label, 'cbi-button-negative', function() {
			self.confirmEngineAction('modem-reset', subject.targetId, label,
				_('This stops only this mobile interface, restarts the modem, waits for the SIM and then verifies or corrects the APN. Mobile connectivity through it will be interrupted temporarily.'),
				_('This runs against %s only.').format(subject.section));
		}, { busy: self.subjectBusy(subject) });
	},

	manualApnControl: function(subject) {
		var self = this;
		return self.control('apply-manual', _('Enter an APN by hand'), 'cbi-button-neutral', function() {
			self.openManualApn(subject);
		}, { busy: self.subjectBusy(subject) });
	},

	/* ---- Overview -------------------------------------------------------- */

	overviewNodes: function() {
		var self = this;
		var subjects = self.subjects || [];

		/* Asked for and not answered yet. Distinct from `emptyRouterNodes`,
		 * which says a read completed and found nothing -- announcing "no
		 * modems" while the inventory is still in flight is the same error as
		 * calling an unread field false. */
		if (self.routerPending())
			return [ pendingLine(_('the modems attached to this router')) ];

		if (!subjects.length)
			return self.emptyRouterNodes();

		var ambiguous = subjects.filter(function(subject) { return subject.ambiguous; });
		var head = [];
		var cards = subjects.map(function(subject) { return self.cardNode(subject); });

		/* With exactly one card the list collapses to a line and the workspace
		 * opens directly: a one-modem router is the common case and must not
		 * pay a click to reach everything. It still expands, and the
		 * router-scoped fan-out lives on the expanded list. */
		if (subjects.length === 1 && !self.overviewExpanded) {
			head.push(E('div', { 'class': 'apn-overview-line' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-neutral apn-overview-toggle',
					'type': 'button',
					'data-apn-nav': 'overview-expand',
					'aria-expanded': 'false',
					'click': function(ev) {
						ev.preventDefault();
						self.overviewExpanded = true;
						self.renderRoute();
					}
				}, [ _('Overview — 1 connection') ])
			]));
		}
		else {
			var actions = [];
			if (self.managedTargets().length)
				actions.push(self.reconcileAllControl());
			head.push(E('div', { 'class': 'apn-overview-head' }, [
				E('h3', {}, [ _('Overview') ]),
				E('div', { 'class': 'apn-button-row' }, actions)
			]));
		}

		if (ambiguous.length > 1)
			head.push(E('p', { 'class': 'apn-ambiguity-note' }, [
				_('%d modems could not be told apart. Removing one of them, or a firmware that reports a serial number, would resolve this.')
					.format(ambiguous.length)
			]));

		/* There is no router-level verdict: a router with two modems has two
		 * answers, and a summary word over them is either wrong for one of
		 * them or too weak to mean anything. */
		return head.concat([ E('div', { 'class': 'apn-cards' }, cards) ]);
	},

	emptyRouterNodes: function() {
		var self = this;
		var inventory = self.documents && self.documents.inventory;
		var nodes = [ E('h3', {}, [ _('Overview') ]) ];
		if (inventory && inventory.error)
			nodes.push(unknownLine(_('The modems attached to this router'),
				_('The optional apn-autoconfig-modem package may be absent, disabled or unable to complete its bounded scan. The APN functions remain independent of it.')));
		else
			nodes.push(E('p', {}, [
				_('No cellular modem was found. Attach a supported modem, or check that its driver packages are installed. This page updates on its own when one appears.')
			]));
		nodes.push(E('details', { 'class': 'apn-details' }, [
			E('summary', {}, [ _('What was looked at') ]),
			table([
				row(_('Modem scan'), inventory && inventory.error ? inventory.error : _('completed, nothing found')),
				row(_('Connection targets'), _('none this program can see'))
			])
		]));
		return nodes;
	},

	/* A card carries the modem's name, the current subscription, the serving
	 * network, registration, bearer state and signal, the running operation if
	 * there is one, the verdict slot, and exactly one primary action. Every
	 * other operation is in the workspace. */
	cardNode: function(subject) {
		var self = this;
		var state = self.connectionState(subject);
		var status = subject.status;

		/* A running operation takes the place a primary action would occupy: a
		 * card must not offer something that competes with what is already
		 * happening to the same modem. The controls themselves are not
		 * removed, they are in the workspace and disabled there — which is the
		 * one thing a disabled control is allowed to mean. */
		var running = self.subjectOperationText(subject);
		var actions = [];
		if (state.primary && !subject.ambiguous && !running)
			actions.push(self.bearerControl(subject, state.primary,
				self.bearerControlLabel(state.primary), self.bearerControlClass(state.primary, true)));

		var head = E('div', { 'class': 'apn-card-head' }, [
			E('button', {
				'class': 'btn cbi-button cbi-button-neutral apn-card-name',
				'type': 'button',
				'data-apn-nav': 'card',
				'click': function(ev) {
					ev.preventDefault();
					self.navigate({ area: 'overview', subject: subject.key, workspace: 'connection' });
				}
			}, [ self.subjectHeading(subject) ]),
			E('div', { 'class': 'apn-button-row apn-card-primary' }, actions)
		]);

		var facts = [];
		facts.push(running
			? E('span', { 'class': 'apn-card-state apn-tone-busy' }, [ running ])
			: E('span', { 'class': 'apn-card-state apn-tone-' + state.tone }, [ state.label ]));
		if (status && !status.error) {
			facts.push(registrationLabel(status));
			var serving = networkLabel(status.serving_operator_name, status.serving_operator_id);
			if (serving)
				facts.push(serving);
			if (status.access_technologies)
				facts.push((status.access_technologies || '').replace(/,/g, ' + '));
			var percent = signalPercent(status.signal_quality);
			if (percent != null)
				facts.push('%s%%'.format(percent));
		}

		var nodes = [ head, E('div', { 'class': 'apn-card-facts' },
			facts.map(function(fact, index) {
				return typeof fact === 'string'
					? E('span', { 'class': 'apn-card-fact' }, [ (index ? '· ' : '') + fact ])
					: fact;
			})) ];

		if (state.note)
			nodes.push(E('p', { 'class': 'apn-card-note' }, [ state.note ]));
		if (state.refusal)
			nodes.push(refusalLine(state.refusal));
		if (state.unknown)
			nodes.push(unknownLine(state.unknown, state.unknownNext));

		/* The verdict slot is text and holds no control: a demoted result is
		 * information, and the action that would replace it is the card's own
		 * secondary action rather than something inside the verdict. */
		var verdict = self.verdictNode(subject);
		if (verdict)
			nodes.push(verdict);

		var secondary = [];
		if (status && !status.error && !subject.ambiguous && subject.targetId &&
			resultState(status) !== 'current' && targetGate(status, 'profile_apply') === 'yes' &&
			(subject.target ? subject.target.managed === true : true))
			secondary.push(self.checkNowControl(subject));
		if (secondary.length)
			nodes.push(E('div', { 'class': 'apn-button-row apn-card-secondary' }, secondary));

		return E('div', {
			'class': 'apn-card-subject' + (subject.ambiguous ? ' apn-card-ambiguous' : ''),
			'data-apn-card': subject.key
		}, nodes);
	},

	/* ---- the workspace ---------------------------------------------------- */

	workspaceNodes: function(subject) {
		var self = this;
		var areas = [
			{ name: 'connection', label: _('Connection') },
			{ name: 'sim', label: _('SIM') },
			{ name: 'esim', label: _('eSIM') },
			{ name: 'apn', label: _('APN') },
			{ name: 'modem', label: _('Modem') },
			{ name: 'diagnostics', label: _('Diagnostics') }
		];

		var tabs = areas.map(function(area) {
			var active = self.route.workspace === area.name;
			return E('button', {
				'class': 'btn cbi-button apn-area-tab' + (active ? ' cbi-button-action apn-area-active' : ''),
				'type': 'button',
				'role': 'tab',
				'data-apn-nav': 'area',
				'data-apn-area': area.name,
				'aria-selected': active ? 'true' : 'false',
				'click': function(ev) {
					ev.preventDefault();
					self.navigate({ area: 'overview', subject: subject.key, workspace: area.name });
				}
			}, [ area.label ]);
		});

		return [
			E('div', { 'class': 'apn-workspace', 'data-apn-workspace': subject.key }, [
				self.workspaceHeader(subject),
				E('div', { 'class': 'apn-area-tabs', 'role': 'tablist' }, tabs),
				E('div', { 'class': 'apn-area', 'role': 'tabpanel' }, self.areaNodes(subject))
			])
		];
	},

	/* The status strip's rule survives the move and is the reason the
	 * workspace has a header at all: a failure or a running operation is never
	 * visible only inside the area it belongs to. */
	workspaceHeader: function(subject) {
		var self = this;
		var state = self.connectionState(subject);
		var status = subject.status;
		var items = [];

		function item(label, value, cssClass) {
			return E('div', { 'class': 'apn-strip-item ' + (cssClass || '') }, [
				E('span', { 'class': 'apn-strip-label' }, [ label ]),
				E('span', { 'class': 'apn-strip-value' }, [ valueNode(value) ])
			]);
		}

		var running = self.subjectOperationText(subject);
		items.push(running
			? item(_('Connection'), running, 'apn-tone-busy')
			: item(_('Connection'), state.label, 'apn-tone-' + state.tone));
		items.push(item(_('Interface'), subject.section || _('none')));
		if (status && !status.error) {
			items.push(item(_('Registration'), registrationLabel(status),
				status.registration_state === 'denied' || status.registration_state === 'emergency-only'
					? 'apn-tone-bad' : ''));
			var verdict = self.verdictNode(subject);
			if (verdict)
				items.push(item(_('Last check'), verdict));
			if (status.incomplete === true)
				items.push(item(_('Readings'), _('some could not be completed in time'), 'apn-tone-neutral'));
		}
		var engine = self.runningDescription(subject);
		if (engine)
			items.push(item(_('Running'), engine, 'apn-tone-busy'));
		/* A running operation is never visible only inside the area it belongs
		 * to, and an eSIM operation belongs to an area a user may not be
		 * looking at while their connection is down for four minutes. */
		var esim = self.esimOperationFor(subject);
		if (esim && !esim.error && esim.busy === true)
			items.push(item(_('eUICC'),
				_('%s — running').format(self.esimActionLabel(esim.action)), 'apn-tone-busy'));
		else if (esim && !esim.error && self.esimTerminalClass(esim.status) === 'partial')
			/* Unfinished business is not something to find only by opening the
			 * area it happened in. It keeps the attention colour here too, and
			 * the detail stays where the action that resolves it is. */
			items.push(item(_('eUICC'),
				_('%s — unfinished').format(self.esimActionLabel(esim.action)), 'apn-tone-warn'));

		return E('div', { 'class': 'apn-workspace-header' }, [
			E('h3', {}, [ self.subjectHeading(subject) ]),
			E('div', { 'class': 'apn-strip' }, items)
		]);
	},

	/* The Modem area is answered by the inventory record, which level 0 already
	 * brought; the other four are answered by this target's status, which is
	 * still in flight. Those four render `pending` rather than their own
	 * `unknown` sentences -- an area that says "could not be determined" about
	 * a read that has not returned is telling the user a read failed, and
	 * offering a retry for one already running. */
	areaNeedsStatus: function(area) {
		return area !== 'modem';
	},

	areaNodes: function(subject) {
		var area = this.route.workspace || 'connection';
		if (this.areaNeedsStatus(area) && this.statusPending(subject))
			return [ pendingLine(_('what this connection is doing')) ];

		switch (area) {
		case 'sim': return this.simAreaNodes(subject);
		case 'esim': return this.esimAreaNodes(subject);
		case 'apn': return this.apnAreaNodes(subject);
		case 'modem': return this.modemAreaNodes(subject);
		case 'diagnostics': return this.diagnosticsAreaNodes(subject);
		}
		return this.connectionAreaNodes(subject);
	},

	/* ---- workspace: Connection -------------------------------------------- */

	connectionAreaNodes: function(subject) {
		var self = this;
		var state = self.connectionState(subject);
		var status = subject.status;
		var nodes = [ E('h4', {}, [ _('Connection') ]) ];

		if (status && status.incomplete === true)
			nodes = nodes.concat(self.incompleteNotice(status));

		var running = self.subjectOperationText(subject);
		var rows = [
			row(_('Interface'), subject.section || _('none')),
			row(_('State'), running || state.label,
				state.key === 'switched-off'
					? _('This connection is down because it was stopped here, not because anything failed. Reconnecting the modem will not bring it back; press Connect when you want it again.')
					: null)
		];
		if (subject.kind === 'modem' && subject.status)
			rows.push(row(_('You asked for'), self.intentLabel(bearerIntent(status)),
				_('What this program was last asked to do with this connection. It is not what the connection is doing, which is the line above.')));
		if (status && !status.error) {
			rows.push(row(_('Registration'), registrationLabel(status),
				_('Whether the modem is registered on a network. APN profiles are never tested before registration succeeds.')));
			rows.push(row(_('Serving network'), networkLabel(status.serving_operator_name, status.serving_operator_id),
				_('The network currently carrying the radio link. While roaming this differs from the provider your APN profile was matched from, which is shown under APN.')));
			rows.push(row(_('Access technology'), (status.access_technologies || '').replace(/,/g, ' + ')));
			rows.push(row(_('Signal'), signalQuality(status.signal_quality)));
			/* The result belongs to the APN area, which is the one that owns
			 * the verdict. It is repeated here only in the one state where it
			 * is about this control — a connection that was wanted and did not
			 * hold — because that is where the reason belongs beside the thing
			 * the user would press. Anywhere else it would be the same fact at
			 * full fidelity in two areas. */
			if (state.key === 'failed' && status.last_result && resultState(status) === 'current')
				rows.push(row(_('Last result'), self.resultDetailNode(status)));
		}
		nodes.push(table(rows));

		if (state.refusal)
			nodes.push(refusalLine(state.refusal));
		if (state.unknown)
			nodes.push(unknownLine(state.unknown, state.unknownNext));
		if (state.note)
			nodes.push(E('p', { 'class': 'apn-area-note' }, [ state.note ]));

		var buttons = [];
		if (state.primary && !subject.ambiguous)
			buttons.push(self.bearerControl(subject, state.primary,
				self.bearerControlLabel(state.primary), self.bearerControlClass(state.primary, true)));
		(state.secondary || []).forEach(function(verb) {
			buttons.push(self.bearerControl(subject, verb,
				self.bearerControlLabel(verb), self.bearerControlClass(verb, false)));
		});
		if (buttons.length)
			nodes.push(E('div', { 'class': 'apn-button-row' }, buttons));

		nodes = nodes.concat(self.adoptionNodes(subject));

		/* Named gap 1: reordering mobile connections needs the modem package's
		 * connection-priority operation, and the read half that would list
		 * every interface competing for the default route. Until then this is
		 * a line and not a list. */
		nodes.push(E('h5', {}, [ _('Mobile route priority') ]));
		nodes.push(plannedLine('route-order',
			_('Planned: reordering mobile connections arrives with the modem package’s connection-priority operation.')));

		return nodes;
	},

	/* Who owns the settings of this connection, and the one operation that
	 * changes the answer.
	 *
	 * It is here rather than under Modem because it is a fact about a
	 * connection: the same modem may be bound to a section this program made,
	 * to one the user made, or to one the user made and then handed over.
	 * Consent changes ownership; displaying the row does not, and neither does
	 * starting or stopping the interface, which is why bearer control is
	 * offered on all three.
	 *
	 * `connection_origin` is the fact and `can_adopt` / `can_release_adoption`
	 * are the gates. An absent origin is unknown: it is what an older backend
	 * looks like from here, and it must not read as "you created this" or as
	 * permission to hand anything over. */
	adoptionNodes: function(subject) {
		var self = this;
		var plan = subject.plan || {};
		if (subject.kind !== 'modem' || plan.error)
			return [];
		var origin = plan.connection_origin;
		if (origin === 'none' || (origin == null && !subject.section))
			return [];

		var nodes = [ E('h5', {}, [ _('Who looks after these settings') ]) ];

		if (origin == null) {
			nodes.push(unknownLine(_('Who owns the settings of this connection'),
				_('The installed version of this program does not report it. Updating the packages would answer it.')));
			return nodes;
		}

		if (origin === 'created') {
			nodes.push(E('p', {}, [
				_('This program created %s and looks after its settings. Removing that setup is under Modem.')
					.format(text(subject.section))
			]));
			return nodes;
		}

		if (origin === 'adopted') {
			/* The managed-in-place explanation that replaces the
			 * user-created-interface notice once the handover has happened. */
			nodes.push(E('p', {}, [
				_('You created %s and asked this program to manage its settings. The interface is still yours: it was not recreated, and the settings it had before are saved so they can be put back.')
					.format(text(subject.section))
			]));
			var release = gate(plan.can_release_adoption);
			if (release === 'yes')
				nodes.push(E('div', { 'class': 'apn-button-row' }, [
					self.adoptionControl(subject, 'release-adoption')
				]));
			else if (release === 'no')
				nodes.push(refusalLine(_('The saved settings for %s could not be validated, so putting them back is not offered. The interface keeps working and nothing is removed.')
					.format(text(subject.section))));
			else
				nodes.push(unknownLine(_('Whether the saved settings can be put back'),
					_('The installed version of this program does not report it. Updating the packages would answer it.')));
			return nodes;
		}

		if (origin === 'external') {
			/* v1's sentence, kept word for word, and now followed by the action
			 * it always implied. */
			nodes.push(E('p', {}, [
				_('This modem belongs to a network interface you created, so its configuration is left alone.')
			]));
			var adopt = gate(plan.can_adopt);
			if (adopt === 'yes') {
				nodes.push(E('p', {}, [
					_('This program can look after its APN instead, without taking the interface away from you.')
				]));
				nodes.push(E('div', { 'class': 'apn-button-row' }, [
					self.adoptionControl(subject, 'adopt')
				]));
			}
			else if (adopt === 'no')
				nodes.push(refusalLine(self.adoptionReasonText(plan.adoption_reason, subject)));
			else
				nodes.push(unknownLine(_('Whether this program can look after these settings'),
					_('The installed version of this program does not report it. Updating the packages would answer it.')));
			return nodes;
		}

		nodes.push(unknownLine(_('Who owns the settings of this connection'),
			_('This program reported an ownership it does not recognise, so no action is offered.')));
		return nodes;
	},

	/* Always the backend's own reason, never the page's guess about why. */
	adoptionReasonText: function(reason, subject) {
		switch (reason) {
		case 'already_owned':
			return _('This program already looks after the settings of %s.').format(text(subject.section));
		case 'ambiguous':
			return _('This modem could not be told apart from another one, so its settings are left alone.');
		case 'conflicting_owner':
			return _('Another component is claiming control of this modem, so its settings are left alone.');
		case 'weak_identity':
			return _('This modem is not identified strongly enough to hand a network interface to it. Taking over settings needs a serial number or an IMEI, not a bus position that can change.');
		case 'no_interface':
			return _('No cellular network interface is bound to this modem, so there is nothing to take over.');
		case 'unsupported_interface':
			return _('The interface bound to this modem is not a cellular one, so it is left alone.');
		case 'not_present':
			return _('This modem is not attached right now.');
		case 'marker_conflict':
			return _('%s carries ownership markings that do not match a complete handover, so it is left alone rather than repaired automatically.')
				.format(text(subject.section));
		}
		return _('This program cannot take over these settings right now.');
	},

	adoptionControl: function(subject, verb) {
		var self = this;
		var labels = {
			adopt: _('Let AutoAPN manage settings'),
			'release-adoption': _('Stop managing settings')
		};
		return self.control(verb === 'adopt' ? 'adopt' : 'release-adoption', labels[verb],
			verb === 'adopt' ? 'cbi-button-action' : 'cbi-button-neutral', function() {
				self.confirmModemAction(subject, verb);
			}, { busy: self.subjectBusy(subject) });
	},

	intentLabel: function(intent) {
		switch (intent) {
		case 'up': return _('Connected');
		case 'down': return _('Disconnected');
		}
		return _('Whatever the program decides');
	},

	resultDetailNode: function(status) {
		var parts = [ status.last_result ];
		if (status.result_code)
			parts.push(_('code %s').format(status.result_code));
		return E('div', { 'class': 'apn-result-current' }, [ parts.join(' · ') ]);
	},

	/* ---- workspace: SIM ---------------------------------------------------- */

	/* Two areas were one until the split, and the reason they are two is worth
	 * keeping written down. Everything here is true of a subscription whatever
	 * kind of card carries it: who the provider is, which network it belongs
	 * to, which slot it sits in. A person who came to look at their SIM gets
	 * all of that and is asked for nothing.
	 *
	 * Managing an eSIM is a different errand and lives in its own area, so that
	 * opening it means "I want to manage an eSIM" and can be allowed to cost
	 * something -- a channel to the card -- that looking at a SIM must never
	 * cost.
	 *
	 * Level 2 is one `esim-query inventory` for this modem, issued when either
	 * area is opened and never before -- not on load, not from a poll, not from
	 * navigating anywhere else. It opens no channel to the card: it is the slot
	 * table, the endpoints on it and what each of them can do.
	 *
	 * Level 3 is `profiles` and `notifications`. On the reference hardware
	 * those take the modem away from ModemManager -- no SIM, no bearer, no
	 * Internet for the duration -- so they are reached from a control a person
	 * pressed and from nowhere else. `interruptingCalls()` in
	 * tests/luci-v2-harness.js counts them beside the two control wrappers for
	 * exactly that reason, and the sweep requires zero of them across load,
	 * every area, Back, Forward and three poll cycles. The probe control the
	 * eSIM area offers is counted there too: it is pressed, never navigated
	 * into. */
	simAreaNodes: function(subject) {
		var self = this;
		var status = subject.status;
		var nodes = [ E('h4', {}, [ _('SIM') ]) ];

		if (!status || status.error)
			nodes.push(unknownLine(_('The subscription in this modem'),
				_('The connection this modem is bound to could not be read just now.')));
		else {
			nodes = nodes.concat(self.incompleteNotice(status));
			nodes.push(E('h5', {}, [ _('Active subscription') ]));
			nodes.push(table([
				row(_('Provider'), simProviderLabel(status)),
				row(_('Home network'), homeNetworkLabel(status),
					_('The network the SIM belongs to, which is what the APN profile is chosen for even while roaming on another one.')),
				row(_('SIM identifier'), sensitiveIdentifier(status.reconciled_iccid || status.iccid, _('SIM identifier'))),
				row(_('Backend slot index'), status.sim_index)
			]));
		}

		nodes = nodes.concat(self.slotsNodes(subject));

		if (status && !status.error)
			nodes.push(advanced([
				row(_('ICCID'), sensitiveIdentifier(status.iccid, _('ICCID'))),
				row(_('IMSI'), sensitiveIdentifier(status.imsi, _('IMSI'))),
				row(_('EID'), sensitiveIdentifier(status.eid, _('EID'))),
				row(_('Modem / control identifier'), status.modem_index)
			]));

		return nodes;
	},

	/* The slot table belongs here rather than beside the eSIM controls: how
	 * many slots a modem has and which one is live is a fact about the modem,
	 * true of a router with no eSIM anywhere on it. Switching between them is
	 * a modem operation and does not become an eSIM operation because one of
	 * the slots happens to hold a chip. */
	slotsNodes: function(subject) {
		var self = this;
		var nodes = [ E('h5', {}, [ _('Slots') ]) ];

		/* A connection whose modem is absent has no slots to report and
		 * nothing that could read them. It is unread, not empty. */
		if (subject.kind !== 'modem' || !subject.modem) {
			nodes.push(unknownLine(_('What each slot of this modem holds'),
				_('The modem is not attached, so nothing can be asked about its slots.')));
			return nodes;
		}

		var modemId = subject.modem.modem_id;
		self.ensureEsimInventory(modemId);
		var inventory = self.esimInventory(modemId);

		if (inventory == null) {
			nodes.push(pendingLine(_('the slots this modem reports')));
			return nodes;
		}
		if (inventory.error) {
			nodes.push(unknownLine(_('What each slot of this modem holds'),
				_('Nothing on this router answered for the eSIM slots just now. The eSIM package may not be installed, or the read did not finish. Leaving this area and coming back asks again. This is unread rather than empty: it is not a statement that there is one slot.')));
			return nodes;
		}

		return nodes.concat(self.slotRowNodes(subject,
			self.esimModemRecord(subject, inventory),
			self.esimEndpointsFor(subject, inventory)));
	},

	/* ---- workspace: eSIM --------------------------------------------------- */

	/* The area exists for every modem, always, and answers one question on
	 * entry: is there an eUICC in the slot that is live right now? Either it
	 * can be managed, and the controls for doing so are here; or it cannot,
	 * and the area says so in the one honest way available to it.
	 *
	 * Nothing here concerns the inactive slot. Whatever is in it is not
	 * powered and cannot be asked, and pretending otherwise would be the one
	 * lie this area is built to avoid. Changing which slot is live is a modem
	 * operation and lives beside the slot table, not here. */
	esimAreaNodes: function(subject) {
		var self = this;
		var nodes = [ E('h4', {}, [ _('eSIM') ]) ];

		if (subject.kind !== 'modem' || !subject.modem) {
			nodes.push(unknownLine(_('Whether there is an eSIM to manage'),
				_('The modem is not attached, so nothing can be asked about the card in it.')));
			return nodes;
		}

		var modemId = subject.modem.modem_id;
		self.ensureEsimInventory(modemId);
		var inventory = self.esimInventory(modemId);

		if (inventory == null) {
			nodes.push(pendingLine(_('what the active slot of this modem holds')));
			return nodes;
		}
		if (inventory.error) {
			nodes.push(unknownLine(_('Whether there is an eSIM to manage'),
				_('Nothing on this router answered about this modem’s card just now. The eSIM package may not be installed, or the read did not finish. Leaving this area and coming back asks again.')));
			nodes.push(plannedLine('esim-read',
				_('Planned: the eUICC under the slot that has one, its subscriptions and their lifecycle arrive with the eSIM package.')));
			return nodes;
		}

		var record = self.esimModemRecord(subject, inventory);
		var endpoints = self.esimEndpointsFor(subject, inventory);

		nodes = nodes.concat(self.esimOperationNodes(subject));
		nodes = nodes.concat(self.activeSlotNodes(subject, record));

		if (endpoints.length) {
			endpoints.forEach(function(endpoint) {
				nodes.push(self.endpointPanel(subject, endpoint));
			});
			return nodes;
		}

		return nodes.concat(self.probeNodes(subject, record));
	},

	/* There is an eUICC this page cannot see, and one control is the whole
	 * difference. A slot table says what a slot holds only where ModemManager
	 * owns the modem; every direct QMI, direct MBIM and AT-only composition
	 * has to be answered by opening the card itself, which the enumeration
	 * does only under an explicit refresh. Without a way to ask, a perfectly
	 * readable eUICC reads as "could not be determined" forever.
	 *
	 * So it is a button and not something entering the area does. Opening a
	 * channel to a card is a deliberate act, and the invariant that navigation
	 * -- load, tabs, Back, Forward, polling -- opens nothing stays literally
	 * true. The backend refuses to open anything at all unless the matrix says
	 * the active slot can be read with no inhibit, no bearer stop and no slot
	 * change, so pressing this on a modem that cannot spare the card costs
	 * nothing and says so. */
	probeNodes: function(subject, record) {
		var self = this;
		var modemId = subject.modem.modem_id;

		if ((self.esimProbing || {})[modemId])
			return [ pendingLine(_('what the card in the active slot says')) ];

		/* An operation has finished and the endpoint has not come back yet.
		 *
		 * For seven to thirteen seconds after an inhibit is released -- twenty
		 * on the reference router, measured 2026-09-10 -- ModemManager is still
		 * re-enumerating the modem it was handed back, and no endpoint resolves
		 * at all. `afterEsimOperation` already waits that out before reading.
		 * What it did not do was say so here, so for the whole of that window
		 * this area rendered a card that had *just been read successfully* as
		 * one nothing had ever asked about, with a button offering to ask it.
		 *
		 * A reader cannot tell that from the real thing and has no reason to
		 * suspect that waiting would change it -- and the button invites them
		 * to pay for an interruption they do not need. An empty wait is the
		 * honest state here; a false one with a control is not. */
		if ((self.esimSettling || {})[modemId])
			return [ pendingLine(_('what the card in the active slot says')) ];

		if (record && record.active_slot_reason === 'requires-bearer-stop')
			return [ E('p', {}, [
				_('The connection is using the channel needed to identify this card. You can review a temporary interruption before starting the search.')
			]), self.control('esim-card-probe', _('Look for an eSIM by stopping the connection'),
				'cbi-button-action', function() { self.openCardProbeConsent(subject); },
				{ busy: self.subjectBusy(subject) }) ];

		var answer = record ? record.active_slot_euicc : null;
		var nodes = [];
		/* The probe itself did not run. That is a different thing from the
		 * card refusing to answer, and it is said separately rather than
		 * folded into the slot's own three-valued answer. */
		if ((self.esimProbeError || {})[modemId])
			nodes.push(unknownLine(_('What the card in the active slot holds'),
				_('Asking the card did not get as far as the card. Nothing was opened and nothing changed; it can be tried again.')));
		nodes.push(E('p', {}, [ answer === 'no'
			? _('There is nothing here to manage. The card can be asked again — a card that was swapped since the last look would answer differently.')
			: _('Nothing has asked the card in the active slot yet. Asking it opens a channel to the card and reads what is on it; it installs nothing and changes no slot.') ]));

		nodes.push(self.control('esim-probe', _('Look for an eSIM in the active slot'),
			'cbi-button-action', function() { self.startEsimProbe(subject); },
			{ busy: self.subjectBusy(subject) }));
		return nodes;
	},

	openCardProbeConsent: function(subject) {
		var self = this;
		if (self.subjectBusy(subject))
			return Promise.resolve();
		return callPlan(esimQueryCommand,
			[ 'card-probe-plan', subject.modem.modem_id ]).then(function(plan) {
			if (plan.version !== 'v1' || plan.available !== true ||
				plan.modem_id !== subject.modem.modem_id || plan.mechanism !== 'bearer-stop' ||
				plan.consent_required !== true || plan.changes_slot !== false || plan.mutates_card !== false)
				throw new Error(_('The router cannot safely offer this search right now: %s')
					.format(plan.unavailable_reason || _('the plan could not be confirmed')));
			var extra = [ E('p', {}, [
				_('The card is only identified. No subscription is installed, enabled or removed, and the active SIM slot stays the same.')
			]), E('p', {}, [
				_('The previous connection setting is restored afterwards. If restoration fails, the result will say so. An interface you had stopped manually stays stopped.')
			]), E('p', {}, [
				_('Closing this page does not cancel an accepted search. Its result can be read when you return.')
			]) ];
			var bound = durationLabel(plan.worst_case_seconds);
			if (bound)
				extra.push(E('p', {}, [ _('Allow up to %s for this operation.').format(bound) ]));
			if (plan.other_uplink_up === 'false')
				extra.push(E('p', {}, [ _('The router will have no Internet access during this interruption.') ]));
			self.showConfirmation(_('Look for an eSIM'),
				_('The connection on %s will stop temporarily so the card can be identified.')
					.format(plan.interrupts_interface || subject.section || ''),
				extra, false, function() {
					return self.startEsimAction(subject, { endpoint_id: '' }, 'card-probe',
						[ '--allow-takeover' ], {}, false);
				});
		}).catch(function(error) {
			ui.addNotification(null, E('p', {}, [ error.message ]), 'error');
		});
	},

	/* The same document the area already reads, asked for again with the card
	 * included. A document replaces the cached one whatever it says: a refusal
	 * the card gave is as much an answer as an eUICC, and keeping the old one
	 * would leave the area claiming a chip a swapped card no longer has.
	 *
	 * A call that fails is not a document and does not replace anything. The
	 * cached inventory is what the SIM area draws its slot table from, and a
	 * probe that never reached the card is no reason to take a slot table that
	 * was read successfully away from a different area. */
	startEsimProbe: function(subject) {
		var self = this;
		var modemId = subject.modem.modem_id;
		if (!self.esimProbing)
			self.esimProbing = {};
		if (self.esimProbing[modemId])
			return;
		self.esimProbing[modemId] = true;
		self.renderRoute();
		/* Kept for the same reason `esimPromise` is: a test waits on the read
		 * rather than guessing how many turns of the queue it takes. */
		if (!self.esimProbeError)
			self.esimProbeError = {};
		self.esimProbeError[modemId] = false;
		self.esimProbePromise = call(esimQueryCommand, [ 'probe', modemId ])
			.then(function(inventory) {
				self.documents.esim[modemId] = inventory;
				self.documents.esimRead[modemId] = true;
			}).catch(function() {
				self.esimProbeError[modemId] = true;
			}).then(function() {
				self.esimProbing[modemId] = false;
				if (!self.userEditing)
					self.renderRoute();
			});
		return self.esimProbePromise;
	},

	/* Issued on entry to this area, once per modem, and never repeated while
	 * the answer stands. A failure is not remembered: it is the difference
	 * between a page that retries when the user comes back and one that has
	 * decided this modem has no eSIM. */
	ensureEsimInventory: function(modemId) {
		var self = this;
		if (!modemId || !self.documents)
			return;
		if (!self.documents.esim)
			self.documents.esim = {};
		if (!self.documents.esimRead)
			self.documents.esimRead = {};
		if (self.documents.esimRead[modemId])
			return;
		self.documents.esimRead[modemId] = 'pending';
		/* Kept so that a test can wait for the staged read rather than guess
		 * how many turns of the queue it takes, exactly as `fillPromise` is. */
		self.esimPromise = call(esimQueryCommand, [ 'inventory', modemId ]).then(function(inventory) {
			self.documents.esim[modemId] = inventory;
			self.documents.esimRead[modemId] = true;
		}).catch(function(error) {
			self.documents.esim[modemId] = { error: error.message };
			self.documents.esimRead[modemId] = true;
		}).then(function() {
			/* And what the eSIM coordinator last did to this modem, which is
			 * how a `partial` left by an operation nobody on this page started
			 * -- a CLI run, another browser, a worker that died -- becomes
			 * visible at all. It is read here rather than at level 0 because
			 * it is this area's fact and a page load must not grow a call per
			 * modem for an area most visits never open.
			 *
			 * A document and a non-zero exit are both possible, so it is read
			 * as a document. */
			return callPlan(esimQueryCommand, [ 'action-status', modemId ])
				.then(function(action) {
					if (!self.documents.esimAction)
						self.documents.esimAction = {};
					self.documents.esimAction[modemId] = action;
					/* An operation that was already running when this area was
					 * opened is followed from here on, exactly as one this page
					 * started would be. */
					if (action && action.busy === true && !(self.esimPending || {})[modemId]) {
						if (!self.esimPending)
							self.esimPending = {};
						self.esimPending[modemId] = { endpointId: action.endpoint_id || '',
							action: action.action || '', follow: false, started: true, waited: 0 };
						self.esimPollPending = true;
					}
				}).catch(function() { /* no package, or nothing to say */ });
		}).then(function() {
			if (!self.userEditing)
				self.renderRoute();
		});
	},

	/* A re-read after an operation, which is a different thing from the first
	 * one: the endpoint is unresolvable for seven to thirteen seconds while
	 * ModemManager re-enumerates the modem it has just been handed back, so
	 * this is what a caller waits on rather than reading straight away. */
	reloadEsimInventory: function(modemId) {
		var self = this;
		if (!modemId || !self.documents)
			return Promise.resolve(null);
		return call(esimQueryCommand, [ 'inventory', modemId ]).then(function(inventory) {
			self.documents.esim[modemId] = inventory;
			self.documents.esimRead[modemId] = true;
			return inventory;
		}).catch(function(error) {
			self.documents.esim[modemId] = { error: error.message };
			self.documents.esimRead[modemId] = true;
			return null;
		});
	},

	esimInventory: function(modemId) {
		var documents = this.documents;
		if (!documents || !documents.esim)
			return null;
		var answer = documents.esim[modemId];
		return answer === undefined ? null : answer;
	},

	esimModemRecord: function(subject, inventory) {
		var modemId = subject.modem.modem_id;
		var modems = inventory && Array.isArray(inventory.modems) ? inventory.modems : [];
		var found = modems.filter(function(entry) { return entry.modem_id === modemId; });
		return found.length === 1 ? found[0] : null;
	},

	esimEndpointsFor: function(subject, inventory) {
		var modemId = subject.modem.modem_id;
		var endpoints = inventory && Array.isArray(inventory.endpoints) ? inventory.endpoints : [];
		return endpoints.filter(function(endpoint) { return endpoint.modem_id === modemId; });
	},

	/* The question this area actually opens with: is there an eUICC in the
	 * slot that is live right now? There are three answers and not two, and
	 * only one of them may be rendered as "none" -- telling somebody they have
	 * no eSIM when the modem was merely busy sends them away from a
	 * subscription they own. */
	activeSlotNodes: function(subject, record) {
		var self = this;
		var status = subject.status;
		var eid = status && !status.error ? status.eid : '';
		var answer = record ? record.active_slot_euicc : null;

		/* Proof beats a report: an EID that was read is an eUICC, whatever the
		 * three-valued field says it could not establish. */
		if (eid)
			return [ E('p', {}, [
				_('The slot in use holds an eUICC. Its identifier ends %s.')
					.format(suffixLabel(String(eid).slice(-4)))
			]) ];
		if (answer === 'yes')
			return [ E('p', {}, [ _('The slot in use holds an eUICC.') ]) ];
		if (answer === 'no')
			return [ E('p', {}, [ _('The slot in use holds no eUICC.') ]) ];
		return [ unknownLine(_('Whether the slot in use holds an eUICC'),
			record && record.active_slot_reason
				? self.slotsUnreadReasonText(record.active_slot_reason)
				: _('Nothing that could answer it was reachable just now.')) ];
	},

	/* One row per slot the modem reports, in the order it reports them. No
	 * slot number implies anything: there is no "eSIM is slot 2", and a slot
	 * with no endpoint is `unknown` rather than empty, because an endpoint is
	 * a claim that a chip is there and its absence is not the negation of one. */
	slotRowNodes: function(subject, record, endpoints) {
		var self = this;
		if (!record || record.slots_read !== true || !(parseInt(record.slot_count, 10) > 0)) {
			var unknown = [ unknownLine(_('What each slot of this modem holds'),
				record && record.slots_unread_reason
					? self.slotsUnreadReasonText(record.slots_unread_reason)
					: _('Nothing on this router publishes the slot table for this modem.')) ];
			/* A modem its owner does not publish slots for can often answer for
			 * itself, and nothing has asked it: discovery never opens a command
			 * port, deliberately, so the table stays unknown until somebody
			 * deliberate asks. Until this control existed the only thing wired
			 * to that question was refreshing the eSIM card read -- a different
			 * area, for a different subject, which nobody could be expected to
			 * guess at. The answer is cached against the modem's enumeration,
			 * so a replug or a slot change asks again.
			 *
			 * Never offered for a ModemManager-owned modem: its table comes
			 * from the daemon, is not missing this way, and the coordinator
			 * refuses the question for it in any case. */
			if (record && record.owner_state && record.owner_state !== 'modemmanager') {
				if ((self.slotProbePending || {})[subject.modem.modem_id])
					return unknown.concat([ pendingLine(_('the slots this modem reports')) ]);
				unknown.push(E('p', {}, [
					_('This modem has not been asked how many slots it has. Asking opens its command port for one question and changes nothing about the modem, the card in it or the connection.')
				]));
				unknown.push(self.slotProbeControl(subject));
			}
			return unknown;
		}

		var count = parseInt(record.slot_count, 10);
		var active = parseInt(record.active_slot, 10);
		var bySlot = {};
		endpoints.forEach(function(endpoint) { bySlot[String(endpoint.slot)] = endpoint; });

		var rows = [];
		for (var slot = 1; slot <= count; slot++) {
			var endpoint = bySlot[String(slot)];
			rows.push(row(_('Slot %s').format(String(slot)),
				self.slotHoldsLabel(endpoint, slot === active)));
		}
		var nodes = [ table(rows) ];

		/* One control per slot that is not the live one, and only where the
		 * modem record says the operation exists for this modem. Which slot is
		 * live is a modem fact, so this is where changing it belongs -- not
		 * beside the eSIM controls, which concern the active slot only and
		 * would be a different feature borrowing this one. */
		var capabilities = (subject.modem && subject.modem.capabilities) || {};
		if (capabilities.slot_switch === true && count > 1) {
			var buttons = [];
			for (var other = 1; other <= count; other++) {
				if (other !== active)
					buttons.push(self.slotSwitchControl(subject, other));
			}
			if (buttons.length)
				nodes.push(E('div', { 'class': 'apn-button-row' }, buttons));
		}
		return nodes;
	},

	slotHoldsLabel: function(endpoint, isActive) {
		var held;
		switch (endpoint ? endpoint.slot_class : '') {
		case 'euicc': held = _('an eUICC'); break;
		case 'physical-sim': held = _('an ordinary SIM'); break;
		case 'empty': held = _('nothing'); break;
		default: held = _('could not be determined');
		}
		/* Whether the slot is the live one, because an enabled profile in an
		 * inactive slot is not a live connection and the two must not read the
		 * same. */
		return isActive ? _('%s — in use').format(held) : held;
	},

	/* The backend's own tokens, in the user's words. */
	slotsUnreadReasonText: function(token) {
		switch (token) {
		case 'slots-not-published':
			return _('ModemManager does not publish this modem’s slot table.');
		case 'owner-conflicting':
			return _('Another component is claiming this modem, so its slots were not asked about.');
		case 'owner-does-not-publish-slots':
			return _('The component that owns this modem does not report its slots.');
		case 'read-abandoned':
			return _('The read ran out of time before the modem answered.');
		case 'not-asked':
			/* Not "the modem did not say": nobody asked it. Seen on the
			 * FM350-GL 2026-09-03, where the page said the modem had not
			 * spoken about a card that was sitting there waiting to be
			 * asked. */
			return _('Nothing has asked the card in the slot that is in use.');
		case 'modem-ambiguous':
			return _('Two modems here cannot be told apart, so neither was asked about its card.');
		case 'requires-bearer-stop':
			/* The one token here that names something the reader can act on.
			 * Found on the FM350-GL 2026-09-05: the modem answers on a single
			 * port, its own data connection dials over that port, and reading
			 * the card beside a live dial would corrupt both -- so the card is
			 * refused and, until this line existed, the page said only that
			 * nothing could be determined. Stopping the interface is not yet an
			 * operation this release offers, so the sentence has to be one
			 * somebody can act on themselves. */
			return _('This modem answers on one port only, and its own data connection is using it. Stopping that interface would let the card be read.');
		case 'card-unreachable':
			return _('No port that could carry the question answered.');
		case 'card-search-incomplete':
			/* Part of the modem answered and part of it said nothing, so what
			 * the answering part reported is not a verdict about the card.
			 * Measured on the FM350-GL 2026-09-09: the port that routes card
			 * commands goes quiet for tens of seconds at a time, and while it
			 * did, the page reported the refusal of the one port that had
			 * answered -- which is the modem's bearer and routes nothing. */
			return _('Only part of this modem answered, so nothing was established about the card. Asking again usually reaches it.');
		}
		return _('The modem did not say.');
	},

	/* ---- the eUICC panel, keyed by endpoint ---- */

	/* Keyed by `endpoint_id` and by nothing else. Not by slot, not by position,
	 * not by modem: a removable eUICC moved to the other modem is the same
	 * panel under a different slot, and keying it by the slot would make it a
	 * different panel with the first one's settings. */
	endpointPanel: function(subject, endpoint) {
		var self = this;
		var nodes = [ E('h5', {}, [ endpoint.slot != null
			? _('eUICC in slot %s').format(String(endpoint.slot)) : _('eUICC') ]) ];

		nodes.push(table([
			row(_('Identifier'), endpoint.eid_known === true
				? suffixLabel(endpoint.eid_suffix) : _('not read'),
				_('An eUICC has a permanent identifier of its own, separate from any subscription on it. Only its last four characters are ever shown.')),
			row(_('Evidence'), endpoint.evidence_tier === 'eid'
				? _('identified by its own identifier') : _('reported by the slot only')),
			row(_('Reachable'), self.endpointReachableLabel(endpoint.reachable))
		]));

		if (endpoint.ambiguous === true) {
			nodes.push(refusalLine(_('This eUICC could not be told apart from another one, so nothing is offered for either of them.')));
			return self.endpointBox(endpoint, nodes);
		}
		if (endpoint.evidence_tier !== 'eid') {
			/* Visible, and no control at all -- not "identify", not "read
			 * properly", not "try anyway". The slot says a chip is there and
			 * its identity was never read, and no operation may target that. */
			nodes.push(refusalLine(_('This slot reports an eUICC whose identifier has not been read, so no operation is offered for it. %s')
				.format(self.endpointReachableReasonText(endpoint.reachable_reason))));
			return self.endpointBox(endpoint, nodes);
		}

		nodes = nodes.concat(self.endpointRunningNodes(subject));
		nodes = nodes.concat(self.endpointReadNodes(subject, endpoint));
		nodes = nodes.concat(self.endpointCardNodes(subject, endpoint));
		nodes = nodes.concat(self.endpointLifecycleNodes(subject, endpoint));
		return self.endpointBox(endpoint, nodes);
	},

	/* What is happening right now, said next to the control that started it.
	 *
	 * The area's own result line is above the slot table and the workspace
	 * header carries a copy, and neither is where somebody who has just pressed
	 * a button in this panel is looking. Observed on the reference router:
	 * pressing "Add a subscription" closed the dialog and, from where the eye
	 * was, nothing happened for a minute. */
	endpointRunningNodes: function(subject) {
		var action = this.esimOperationFor(subject);
		if (!action || action.error || action.busy !== true)
			return [];
		return [ E('p', { 'class': 'apn-tone-busy' }, [
			_('%s is running. The connection is interrupted while it happens, and this page follows it.')
				.format(this.esimActionLabel(action.action))
		] ) ];
	},

	endpointBox: function(endpoint, nodes) {
		return E('div', {
			'class': 'apn-endpoint',
			'data-apn-endpoint': endpoint.endpoint_id || ''
		}, nodes);
	},

	endpointReachableLabel: function(reachable) {
		switch (reachable) {
		case 'yes': return _('yes');
		case 'requires-inhibit': return _('only by interrupting the connection');
		case 'requires-bearer-stop': return _('only by stopping the connection');
		case 'requires-slot-change': return _('only from the other SIM slot');
		case 'no': return _('no');
		}
		return _('could not be determined');
	},

	endpointReachableReasonText: function(token) {
		switch (token) {
		case 'owner-modemmanager':
			return _('ModemManager is holding this modem.');
		case 'owner-conflicting':
			return _('Two components are claiming this modem at once.');
		case 'owner-transitioning':
			return _('An operation on this modem is still finishing.');
		case 'slot-inactive':
			return _('The eUICC is in a slot that is not the one in use.');
		case 'transport-unavailable':
			return _('No way of talking to this eUICC is available on this router.');
		case 'lpa-unavailable':
			return _('The software that talks to eUICCs is not installed.');
		case 'read-abandoned':
			return _('The read ran out of time before the modem answered.');
		case 'endpoint-ambiguous':
			return _('This eUICC could not be told apart from another one.');
		case 'not-supported':
			return _('This composition cannot reach an eUICC at all.');
		}
		return '';
	},

	/* What the panel offers, from the backend's `reachable` answer and never
	 * from one this page derived. */
	endpointReadNodes: function(subject, endpoint) {
		var self = this;
		var nodes = [];
		var key = self.endpointKey(endpoint);
		var refusal = (self.esimRefusals || {})[key];
		if (refusal)
			nodes.push(refusalLine(refusal));

		switch (endpoint.reachable) {
		case 'yes':
			nodes.push(E('div', { 'class': 'apn-button-row' }, [
				self.esimReadControl(subject, endpoint)
			]));
			return nodes;
		case 'requires-inhibit':
		case 'requires-bearer-stop':
			/* Exactly one control, and it opens the consent dialog rather than
			 * reading anything. The dialog is built from `read-takeover-plan`
			 * and from nothing else, and the plan is fetched when the control
			 * is pressed: asking for one per endpoint on entry would put a
			 * per-endpoint read back on the path P7 took it off. Where the
			 * plan refuses, the dialog is never opened and the refusal appears
			 * here instead -- a precondition is not something to wait out. */
			nodes.push(E('div', { 'class': 'apn-button-row' }, [
				self.esimTakeoverControl(subject, endpoint)
			]));
			return nodes;
		case 'requires-slot-change':
			nodes.push(refusalLine(_('This eUICC is in slot %s, which is not the slot in use. Reaching it means changing which slot is active, which is an operation on the modem rather than on the card.')
				.format(String(endpoint.slot))));
			/* The same control the slot table offers, on the modem it belongs
			 * to. It is repeated here rather than linked to because this is
			 * where somebody stands when they find out they need it -- but it
			 * is still the modem's operation, and pressing it here reaches
			 * exactly the same plan and the same consent. */
			if (((subject.modem && subject.modem.capabilities) || {}).slot_switch === true
				&& endpoint.slot != null)
				nodes.push(E('div', { 'class': 'apn-button-row' }, [
					self.slotSwitchControl(subject, endpoint.slot)
				]));
			return nodes;
		case 'no':
			nodes.push(refusalLine(_('This eUICC cannot be reached on this router, and no operation would change that. %s')
				.format(self.endpointReachableReasonText(endpoint.reachable_reason))));
			return nodes;
		}
		nodes.push(unknownLine(_('Whether this eUICC can be reached'),
			_('%s Leaving this area and coming back asks again.')
				.format(self.endpointReachableReasonText(endpoint.reachable_reason))));
		return nodes;
	},

	endpointKey: function(endpoint) {
		return (endpoint && endpoint.endpoint_id) || '';
	},

	esimReadControl: function(subject, endpoint) {
		var self = this;
		return self.control('esim-read', _('Read this eUICC'), 'cbi-button-action', function() {
			self.startEsimRead(subject, endpoint);
		}, { busy: self.subjectBusy(subject) });
	},

	esimTakeoverControl: function(subject, endpoint) {
		var self = this;
		return self.control('esim-takeover', _('Read this eUICC'), 'cbi-button-action', function() {
			self.openTakeoverConsent(subject, endpoint);
		}, { busy: self.subjectBusy(subject) });
	},

	esimRefuse: function(endpoint, message) {
		if (!this.esimRefusals)
			this.esimRefusals = {};
		this.esimRefusals[this.endpointKey(endpoint)] = message;
		if (!this.userEditing)
			this.renderRoute();
	},

	esimClearRefusal: function(endpoint) {
		if (this.esimRefusals)
			delete this.esimRefusals[this.endpointKey(endpoint)];
	},

	/* ---- the consent that makes an unreachable eUICC readable ---- */

	/* The dialog is built from `read-takeover-plan` and from nothing else, and
	 * the plan is asked for here rather than on entry: a plan per endpoint on
	 * every visit is a per-endpoint read on the path P7 took reads off. A
	 * frontend that cannot get a plan does not offer the takeover, so a plan
	 * that refuses replaces the control with its refusal instead of opening a
	 * dialog -- a precondition is not something to wait out. */
	openTakeoverConsent: function(subject, endpoint) {
		var self = this;
		if (self.subjectBusy(subject))
			return;
		self.esimClearRefusal(endpoint);
		return callPlan(esimQueryCommand,
			[ 'read-takeover-plan', subject.modem.modem_id, endpoint.endpoint_id ]
		).then(function(plan) {
			if (plan.available !== true) {
				self.esimRefuse(endpoint, self.takeoverRefusalText(plan));
				return;
			}
			self.showTakeoverDialog(subject, endpoint, plan);
		}).catch(function(error) {
			self.esimRefuse(endpoint,
				_('What reading this eUICC would interrupt could not be established, so it is not offered: %s')
					.format(error.message));
		});
	},

	takeoverRefusalText: function(plan) {
		switch (plan.unavailable_reason) {
		case 'already-reachable':
			return _('This eUICC can already be read without interrupting anything.');
		case 'slot-change-refused':
			return _('This eUICC is in a slot that is not in use, and changing the active slot is never done as part of a read.');
		case 'not-implemented':
			return _('Reading this eUICC by interrupting the connection is not implemented for this composition.');
		case 'lpa-unavailable':
			return _('The software that talks to eUICCs is not installed.');
		}
		return _('Reading this eUICC is not offered right now: %s')
			.format(plan.unavailable_reason || _('the reason was not given'));
	},

	showTakeoverDialog: function(subject, endpoint, plan) {
		var self = this;
		var iface = plan.interrupts_interface || subject.section || '';
		var bound = durationLabel(plan.worst_case_seconds);
		var extra = [];

		/* 2. How long, in the units a person experiences it in, taken from the
		 *    plan's bounded worst case and never from a number this page chose.
		 *    It is a ceiling and it is named as one. */
		if (bound)
			extra.push(E('p', {}, [
				_('It will take up to %s. That is the longest it may take, not how long it usually takes.')
					.format(bound)
			]));
		else
			extra.push(E('p', {}, [
				_('How long it may take was not stated by this router, so it is not being promised.')
			]));
		/* 3. What happens to what it interrupted, on every ending there is. */
		extra.push(E('p', {}, [
				_('The previous connection setting is restored afterwards. If restoration fails, the result will say so. An interface you had stopped manually stays stopped.')
		]));
		/* 4. That this is an operation with an identity, and that the page will
		 *    follow it rather than guess. */
		extra.push(E('p', {}, [
			_('This starts an operation with an identifier of its own. This page follows it and reports what it ends with; closing the page does not stop it.')
		]));
		if (plan.reuses_existing_inhibit === true)
			extra.push(E('p', {}, [
				_('Another component is already holding this modem for its own reasons, so that hold is reused rather than a second one taken.')
			]));
		if (plan.other_uplink_up === 'false')
			extra.push(E('p', {}, [
				_('This modem is the only way out of this router right now, so the router has no Internet access while it runs.')
			]));
		extra.push(E('p', { 'class': 'apn-confirm-scope' }, [
			_('This runs against %s only.').format(iface || subject.section || '')
		]));

		/* 1. What will be interrupted, named as the user knows it. */
		self.showConfirmation(_('Read this eUICC'),
			_('Reading this eUICC means taking the modem away from what is using it, so the connection on %s stops while it happens.')
				.format(iface),
			extra, false, function() {
				self.startTakeover(subject, endpoint);
			});
	},

	startTakeover: function(subject, endpoint) {
		var self = this;
		return self.startEsimAction(subject, endpoint, 'read-takeover', [], {}, true);
	},

	/* ---- level 3: the card itself ---- */

	/* Reached from a control a person pressed, and from nothing else. For an
	 * endpoint that is already reachable this is the whole operation; for one
	 * behind an inhibit it is what the consented takeover was for, and the
	 * lists come back from the cache the takeover filled rather than from a
	 * second interruption. */
	startEsimRead: function(subject, endpoint) {
		var self = this;
		var key = self.endpointKey(endpoint);
		if (!self.esimCardPending)
			self.esimCardPending = {};
		if (self.esimCardPending[key])
			return Promise.resolve();
		self.esimCardPending[key] = true;
		self.esimClearRefusal(endpoint);
		if (!self.userEditing)
			self.renderRoute();
		return self.readEndpointCard(subject.modem.modem_id, endpoint).then(function() {
			delete self.esimCardPending[key];
			if (!self.userEditing)
				self.renderRoute();
		});
	},

	readEndpointCard: function(modemId, endpoint) {
		var self = this;
		var key = self.endpointKey(endpoint);
		if (!self.documents.esimCard)
			self.documents.esimCard = {};
		var card = { profiles: null, notifications: null };
		/* One after another, for the reason every other read on this page is:
		 * LuCI serialises them anyway, and issuing them together withholds the
		 * first answer until the second arrives. */
		return call(esimQueryCommand, [ 'profiles', modemId, endpoint.endpoint_id ])
			.catch(function(error) { return { error: error.message }; })
			.then(function(profiles) {
				card.profiles = profiles;
				return call(esimQueryCommand, [ 'notifications', modemId, endpoint.endpoint_id ])
					.catch(function(error) { return { error: error.message }; });
			}).then(function(notifications) {
				card.notifications = notifications;
				self.documents.esimCard[key] = card;
			});
	},

	esimCard: function(endpoint) {
		var documents = this.documents;
		if (!documents || !documents.esimCard)
			return null;
		var card = documents.esimCard[this.endpointKey(endpoint)];
		return card === undefined ? null : card;
	},

	/* What was found on the card, once somebody asked. Until then this is
	 * absent rather than empty: an eUICC nobody has read is not an eUICC with
	 * no subscriptions on it. */
	endpointCardNodes: function(subject, endpoint) {
		var self = this;
		var key = self.endpointKey(endpoint);
		if ((self.esimCardPending || {})[key])
			return [ pendingLine(_('the subscriptions on this eUICC')) ];
		var card = self.esimCard(endpoint);
		if (!card)
			return [];

		var nodes = [];
		nodes = nodes.concat(self.profileListNodes(subject, endpoint, card.profiles));
		nodes = nodes.concat(self.notificationListNodes(subject, endpoint, card.notifications));
		return nodes;
	},

	profileListNodes: function(subject, endpoint, document) {
		var self = this;
		var nodes = [ E('h6', {}, [ _('Subscriptions on this eUICC') ]) ];
		if (!document || document.error) {
			nodes.push(unknownLine(_('The subscriptions on this eUICC'),
				_('The read did not produce a list. Reading it again would answer it.')));
			return nodes;
		}
		/* `null` is a read that did not happen, and it is not an empty card. */
		if (!Array.isArray(document.profiles)) {
			if (self.cardChangedByLastOperation(subject))
				/* Not a failure, and saying "could not be determined" here read
				 * as one: the operation invalidated the list on purpose,
				 * because after a write the old one is a lie. */
				nodes.push(E('p', { 'class': 'apn-area-note' }, [
					_('The card changed, so the list that was here is no longer true. Read the eUICC to see what is on it now.')
				]));
			else
				nodes.push(unknownLine(_('The subscriptions on this eUICC'),
					_('Nothing was read from the card, so this is unread rather than empty.')));
			return nodes;
		}
		nodes = nodes.concat(self.readAgeNodes(document));
		nodes = nodes.concat(self.cardResourceNodes(document));
		if (!document.profiles.length) {
			nodes.push(E('p', {}, [ _('This eUICC holds no subscriptions.') ]));
			return nodes;
		}
		document.profiles.forEach(function(profile) {
			nodes.push(self.profileNode(subject, endpoint, profile));
		});
		return nodes;
	},

	/* Whether the last thing this modem did wrote to the card. Used only to
	 * choose between two sentences: an invalidated list and a read that failed
	 * are different situations and must not share one. */
	cardChangedByLastOperation: function(subject) {
		var action = this.esimOperationFor(subject);
		if (!action || action.error || action.busy === true)
			return false;
		switch (action.action) {
		case 'download':
		case 'enable':
		case 'disable':
		case 'nickname':
		case 'delete':
		case 'notification-remove':
			return this.esimTerminalClass(action.status) !== 'idle';
		}
		return false;
	},

	profileNode: function(subject, endpoint, profile) {
		var self = this;
		var rows = [
			row(_('Provider'), self.profileProviderLabel(profile)),
			row(_('Subscription identifier'), suffixLabel(profile.iccid_suffix),
				_('Only the last four digits of a subscription’s identifier are ever shown. It is what a deletion asks you to type back.')),
			row(_('State'), self.profileStateLabel(profile.state)),
			row(_('Kind'), self.profileClassLabel(profile['class']))
		];
		if (profile.nickname)
			rows.splice(1, 0, row(_('Name you gave it'), profile.nickname));
		return E('div', {
			'class': 'apn-profile',
			'data-apn-profile': profile.profile_id || ''
		}, [ table(rows) ].concat(self.profileControlNodes(subject, endpoint, profile)));
	},

	profileProviderLabel: function(profile) {
		if (profile.provider_name)
			return profile.provider_name;
		if (profile.profile_name)
			return profile.profile_name;
		if (profile.provider_mccmnc)
			return _('Network %s').format(profile.provider_mccmnc);
		return _('Unnamed subscription');
	},

	profileStateLabel: function(state) {
		switch (state) {
		case 'enabled': return _('in use');
		case 'disabled': return _('not in use');
		}
		return _('could not be determined');
	},

	profileClassLabel: function(value) {
		switch (value) {
		case 'operational': return _('an ordinary subscription');
		case 'provisioning': return _('a provisioning profile');
		case 'test': return _('a test profile');
		}
		return _('could not be determined');
	},

	/* A cached list is not a current observation and is never presented as
	 * one. The backend publishes the age; the page says it. */
	readAgeNodes: function(document) {
		if (!document || document.read_state !== 'cached')
			return [];
		var age = parseInt(document.read_age_seconds, 10);
		return [ E('p', { 'class': 'apn-area-note' }, [
			age > 0
				? _('Read from the card %s ago, not just now.').format(durationLabel(age))
				: _('Read from the card a moment ago, not just now.')
		] ) ];
	},

	/* What the card said it had left when it was last read.
	 *
	 * Shown as a fact and never as a prediction. Nothing in the protocol says
	 * how large a subscription is before it arrives -- the card decides when it
	 * has the package, which is why there is a refusal for exactly that -- so
	 * this page must not turn the number into "this one will fit". Where there
	 * is almost nothing left it says so about the card, which is an observation
	 * a person can act on, and still leaves the attempt as the answer. */
	cardResourceNodes: function(document) {
		var free = document && document.free_memory_bytes;
		var apps = document && document.installed_applications;
		if (!(typeof free === 'number') && !(typeof apps === 'number'))
			return [];
		var nodes = [];
		var rows = [];
		if (typeof free === 'number')
			rows.push(row(_('Free space on this eUICC'), this.bytesLabel(free),
				_('What the eUICC reported when it was last read. How much room a subscription needs is not known until it arrives, so this cannot say in advance whether one will fit — one measured on this project’s own test card took about 72 KB.')));
		if (typeof apps === 'number')
			/* Not a count of subscriptions. `installedApplication` is the
			 * card's own count of applications in the GlobalPlatform sense, and
			 * on the reference eUICC it reads 0 beside five subscriptions --
			 * which is correct and reads as a contradiction unless the label
			 * says which of the two it is. */
			rows.push(row(_('Applications on it'), String(apps),
				_('Small programs installed on the card itself, in the sense its operating system counts them. Subscriptions are listed separately below, and a card can report no applications while holding several of them.')));
		nodes.push(table(rows));
		/* The threshold is measured rather than guessed, and it is still not a
		 * gate. On the reference eUICC on 2026-09-03 one downloaded profile
		 * took free space from 138 306 to 66 185 bytes and a deletion returned
		 * every byte of it -- about 72 KB for one subscription. So below
		 * roughly that there is very likely no room for another, and the card
		 * is still the one that decides. The first version of this line used
		 * 32 KB, which was a guess and would have stayed silent on a card that
		 * had no room. */
		if (typeof free === 'number' && free < 73728)
			nodes.push(E('p', { 'class': 'apn-area-note' }, [
				_('There is very little room left on this eUICC. A new subscription will probably be refused — the card decides when it has one, and it refuses before writing anything.')
			]));
		return nodes;
	},

	bytesLabel: function(value) {
		if (!(value >= 1024))
			return _('%s bytes').format(String(value));
		return _('%s KB').format(String(Math.round(value / 1024)));
	},

	/* Whether this endpoint's messages are worth a card read the person has not
	 * asked for. They are readable exactly where the subscriptions are. */
	endpointMayBeRead: function(endpoint) {
		switch (endpoint && endpoint.reachable) {
		case 'yes':
		case 'requires-inhibit':
		case 'requires-bearer-stop':
			return true;
		}
		return false;
	},

	/* The same decision the endpoint's own control makes, in one place: a
	 * reachable endpoint is read, and one behind an inhibit asks for consent
	 * first. Nothing here decides that a card can be reached -- it reads the
	 * backend's `reachable` answer, like every other caller. */
	beginEndpointRead: function(subject, endpoint) {
		if (endpoint.reachable === 'yes')
			return this.startEsimRead(subject, endpoint);
		return this.openTakeoverConsent(subject, endpoint);
	},

	esimMessagesShown: function(endpoint) {
		return !!(this.esimMessagesOpen || {})[this.endpointKey(endpoint)];
	},

	/* Opening is free whenever the read that filled this panel also read the
	 * messages, which is every read a person starts by hand: one takeover
	 * brings back both lists. It costs a card read only after an operation
	 * that wrote to the card, because a write invalidates the list rather than
	 * refreshing it, and then the control says so and the consent dialog
	 * states the interruption. */
	showMessagesControl: function(subject, endpoint, known) {
		var self = this;
		var readable = self.endpointMayBeRead(endpoint);
		var label = known ? _('Show the messages')
			: _('Read the messages from the card');
		return self.control('esim-messages-show', label, 'cbi-button-neutral', function() {
			if (!self.esimMessagesOpen)
				self.esimMessagesOpen = {};
			self.esimMessagesOpen[self.endpointKey(endpoint)] = true;
			if (!known && readable)
				return self.beginEndpointRead(subject, endpoint);
			if (!self.userEditing)
				self.renderRoute();
		}, { busy: !known && readable && self.subjectBusy(subject) });
	},

	/* Offered inside the opened section so that an unread list is answerable
	 * where it is read, rather than by sending somebody back up the page. It
	 * is the endpoint's own read, not a second kind of one. */
	messagesReadAgainNodes: function(subject, endpoint) {
		var self = this;
		if (!self.endpointMayBeRead(endpoint))
			return [];
		return [ E('div', { 'class': 'apn-button-row' }, [
			self.control('esim-messages-read', _('Read the messages from the card'),
				'cbi-button-neutral', function() {
					self.beginEndpointRead(subject, endpoint);
				}, { busy: self.subjectBusy(subject) })
		]) ];
	},

	/* Folded away by default. Somebody who opens this area came for their
	 * subscriptions; the messages are what the card owes the company that
	 * issued one, they are read far less often than the list above them, and
	 * before this they announced "could not be determined" beside a freshly
	 * updated list whenever an install had just invalidated them -- which
	 * reads as a fault rather than as the honest gap it is. Hiding the cost
	 * behind a control is what the subscription list itself already does. */
	notificationListNodes: function(subject, endpoint, document) {
		var self = this;
		var nodes = [ E('h6', {}, [ _('Messages waiting to be sent') ]) ];
		var known = !!document && !document.error && Array.isArray(document.notifications);
		if (!self.esimMessagesShown(endpoint)) {
			nodes.push(E('p', {}, [
				_('When a subscription is added, switched on, switched off or removed, the eUICC writes a message for the company that issued it. They are kept out of the way here because they are needed far less often than the subscriptions above.')
			]));
			if (known && document.notifications.length)
				nodes.push(E('p', {}, [
					_('Waiting to be sent: %s').format(String(document.notifications.length))
				]));
			nodes.push(E('div', { 'class': 'apn-button-row' }, [
				self.showMessagesControl(subject, endpoint, known)
			]));
			return nodes;
		}
		if (!document || document.error) {
			nodes.push(unknownLine(_('The messages waiting on this eUICC'),
				_('The read did not produce a list. Reading it again would answer it.')));
			nodes = nodes.concat(self.messagesReadAgainNodes(subject, endpoint));
			return nodes;
		}
		if (!Array.isArray(document.notifications)) {
			nodes.push(unknownLine(_('The messages waiting on this eUICC'),
				_('Nothing was read from the card, so this is unread rather than empty.')));
			nodes = nodes.concat(self.messagesReadAgainNodes(subject, endpoint));
			return nodes;
		}
		nodes.push(E('p', {}, [
			_('When a subscription is added, switched on, switched off or removed, the eUICC writes a message for the company that issued it. The message stays on the card until that company has taken it.')
		]));
		if (!document.notifications.length) {
			nodes.push(E('p', {}, [ _('Nothing is waiting to be sent.') ]));
			return nodes;
		}
		document.notifications.forEach(function(notification) {
			nodes.push(self.notificationNode(subject, endpoint, notification));
		});
		return nodes;
	},

	notificationNode: function(subject, endpoint, notification) {
		var self = this;
		/* A message on the card has not been taken. That is what being on the
		 * card means, and saying it once above the list left a reader asking
		 * of each line whether it had gone -- particularly after a send, which
		 * succeeds and changes nothing here, because the issuer accepting it
		 * is a separate thing from the transport carrying it. */
		var sentHere = !!((self.esimSentHere || {})[self.endpointKey(endpoint)] || {})[
			String(notification.sequence)];
		var rows = [
			row(_('About'), self.notificationOperationLabel(notification.operation)),
			row(_('Addressed to'), text(notification.address)),
			row(_('Subscription'), notification.profile_id
				? suffixLabel(self.profileSuffixFor(endpoint, notification.profile_id))
				: _('a subscription this card no longer lists')),
			row(_('State'), sentHere
				? _('sent from this router, and still waiting to be taken')
				: _('waiting to be taken'),
				sentHere
					? _('This router sent it and the transport was verified. It stays on the card until the company that issued the subscription takes it, which is a separate step this router does not control.')
					: _('It is on the card, which is where a message waits until the company that issued the subscription takes it. Whether this router has already sent it is not something the card records.'))
		];
		return E('div', {
			'class': 'apn-notification',
			'data-apn-notification': String(notification.sequence)
		}, [ table(rows) ].concat(self.notificationControlNodes(subject, endpoint, notification)));
	},

	profileSuffixFor: function(endpoint, profileId) {
		var card = this.esimCard(endpoint);
		var profiles = card && card.profiles && Array.isArray(card.profiles.profiles)
			? card.profiles.profiles : [];
		var found = profiles.filter(function(profile) { return profile.profile_id === profileId; });
		return found.length ? found[0].iccid_suffix : '';
	},

	notificationOperationLabel: function(operation) {
		switch (operation) {
		case 'install': return _('a subscription that was added');
		case 'enable': return _('a subscription that was switched on');
		case 'disable': return _('a subscription that was switched off');
		case 'delete': return _('a subscription that was removed');
		}
		return _('a change to this card');
	},

	/* ---- what may be done to a subscription ---- */

	/* Every control here is gated by the endpoint's own capability field and by
	 * the profile's own state, and by nothing this page worked out. A profile
	 * whose state could not be read may not be targeted at all: "probably
	 * disabled" is not a thing to delete a subscription on. */
	profileControlNodes: function(subject, endpoint, profile) {
		var self = this;
		var caps = endpoint.capabilities || null;
		var nodes = [];

		if (profile.state !== 'enabled' && profile.state !== 'disabled') {
			nodes.push(refusalLine(_('This subscription’s state could not be read, so nothing is offered for it.')));
			return nodes;
		}

		var buttons = [];
		var enable = caps ? gate(caps.enable) : 'unknown';
		var disable = caps ? gate(caps.disable) : 'unknown';
		var rename = caps ? gate(caps.nickname) : 'unknown';
		var remove = caps ? gate(caps['delete']) : 'unknown';

		if (profile.state === 'disabled' && enable === 'yes')
			buttons.push(self.control('esim-enable', _('Use this one'), 'cbi-button-action',
				function() { self.openSwitchConsent(subject, endpoint, profile, 'enable'); },
				{ busy: self.subjectBusy(subject) }));
		if (profile.state === 'enabled' && disable === 'yes')
			buttons.push(self.control('esim-disable', _('Stop using this one'), 'cbi-button-neutral',
				function() { self.openSwitchConsent(subject, endpoint, profile, 'disable'); },
				{ busy: self.subjectBusy(subject) }));
		if (rename === 'yes')
			buttons.push(self.control('esim-nickname', _('Rename'), 'cbi-button-neutral',
				function() { self.openNicknameDialog(subject, endpoint, profile); },
				{ busy: self.subjectBusy(subject) }));
		/* A subscription in use is refused by `delete-plan` with
		 * `profile_enabled`, so the page does not draw a control the backend
		 * is going to refuse -- it says why instead. */
		if (profile.state === 'disabled' && remove === 'yes')
			buttons.push(self.control('esim-delete', _('Delete'), 'cbi-button-remove',
				function() { self.openDeleteFlow(subject, endpoint, profile); },
				{ busy: self.subjectBusy(subject) }));

		if (buttons.length)
			nodes.push(E('div', { 'class': 'apn-button-row' }, buttons));
		if (profile.state === 'enabled' && remove === 'yes')
			nodes.push(E('p', { 'class': 'apn-area-note' }, [
				_('A subscription that is in use cannot be removed. Stop using it first.')
			]));
		return nodes;
	},

	/* One explanation for the whole group rather than six. The eSIM package
	 * decides all of them together -- a proven endpoint, a reachable one and an
	 * installed LPA -- so six separate refusals would be one fact repeated. */
	endpointLifecycleNodes: function(subject, endpoint) {
		var self = this;
		var caps = endpoint.capabilities || null;
		var nodes = [];
		/* Nothing is offered on a card nobody has looked at. An endpoint that
		 * needs a takeover offers exactly one control -- the read -- and
		 * writing to a card whose contents are unknown is not something to put
		 * beside it. Once a read has happened, this is what may be done. */
		if (!self.esimCard(endpoint))
			return nodes;
		var download = caps ? gate(caps.download) : 'unknown';

		if (download === 'yes') {
			nodes.push(E('div', { 'class': 'apn-button-row' }, [
				self.control('esim-download', _('Add a subscription'), 'cbi-button-action',
					function() { self.openDownloadDialog(subject, endpoint); },
					{ busy: self.subjectBusy(subject) })
			]));
			return nodes;
		}
		if (download === 'no') {
			nodes.push(refusalLine(_('Adding, renaming, switching and removing subscriptions are not offered for this eUICC. %s')
				.format(self.endpointReachableReasonText(endpoint.reachable_reason) ||
					_('The software that talks to eUICCs is not installed, or this eUICC is not proven.'))));
			return nodes;
		}
		nodes.push(unknownLine(_('What may be done to the subscriptions on this eUICC'),
			_('The installed version of this program does not report it. Updating the packages would answer it.')));
		return nodes;
	},

	/* ---- switching which subscription is in use ---- */

	/* The estimate and the bound are kept visibly apart, because they are two
	 * different promises: one is what four measured switches took, and the
	 * other is a watchdog sum that is never a schedule. If either is absent,
	 * inverted or unreadable the page invents nothing and does not offer the
	 * operation. */
	openSwitchConsent: function(subject, endpoint, profile, action) {
		var self = this;
		if (self.subjectBusy(subject))
			return;
		self.esimClearRefusal(endpoint);
		return callPlan(esimQueryCommand,
			[ 'switch-plan', subject.modem.modem_id, endpoint.endpoint_id, action ]
		).then(function(plan) {
			if (plan.available !== true) {
				self.esimRefuse(endpoint, _('Changing which subscription is in use is not offered right now: %s')
					.format(self.esimPlanReasonText(plan.unavailable_reason)));
				return;
			}
			var expected = parseInt(plan.expected_seconds, 10);
			var bound = parseInt(plan.rollback_default === true
				? plan.worst_case_with_rollback_seconds : plan.worst_case_seconds, 10);
			if (!(expected > 0) || !(bound > 0) || bound < expected) {
				self.esimRefuse(endpoint,
					_('How long this would take was not stated in a way this page can use, so it is not offered.'));
				return;
			}
			self.showSwitchDialog(subject, endpoint, profile, action, plan, expected, bound);
		}).catch(function(error) {
			self.esimRefuse(endpoint,
				_('What changing the subscription in use would do could not be established, so it is not offered: %s')
					.format(error.message));
		});
	},

	showSwitchDialog: function(subject, endpoint, profile, action, plan, expected, bound) {
		var self = this;
		var iface = plan.interrupts_interface || subject.section || '';
		var title = action === 'enable' ? _('Use this subscription') : _('Stop using this subscription');
		var extra = [];

		/* The hard ceiling, named as one and named second. */
		extra.push(E('p', {}, [
			plan.rollback_default === true
				? _('It is never allowed to take more than %s, which includes putting the previous subscription back if this one does not work.')
					.format(durationLabel(bound))
				: _('It is never allowed to take more than %s.').format(durationLabel(bound))
		]));
		extra.push(E('p', {}, [
			_('The connection on %s stops while it happens.').format(iface)
		]));
		if (plan.may_reset === true)
			extra.push(E('p', {}, [
				_('This modem may have to be restarted as part of it, which is inside the time above.')
			]));
		extra.push(E('p', {}, [ plan.expects_bearer === true
			? _('A working connection is part of what this is measured by: if it does not come back, the operation reports that rather than calling itself finished.')
			: _('This deliberately leaves the modem with no subscription in use, so the connection not coming back is the expected outcome and not a failure.') ]));
		extra.push(E('p', {}, [ self.issuerReportedAtText(plan.issuer_reported_at) ]));
		extra.push(E('p', { 'class': 'apn-confirm-scope' }, [
			_('This runs against %s only.').format(iface || subject.section || '')
		]));

		/* The measured estimate, leading, and never called a maximum. */
		self.showConfirmation(title,
			_('This usually takes about %s. The subscription ending %s is %s.').format(
				durationLabel(expected), suffixLabel(profile.iccid_suffix),
				action === 'enable' ? _('switched on') : _('switched off')),
			extra, false, function() {
				self.startEsimAction(subject, endpoint, action, [ profile.profile_id ], {}, true);
			});
	},

	issuerReportedAtText: function(value) {
		switch (value) {
		case 'after-recovery':
			return _('The company that issued the subscription is told once the connection is back, because telling them needs the network this brings back.');
		case 'after-recovery-if-other-uplink':
			return _('The company that issued the subscription can only be told through another connection, because this one is what is being switched off.');
		}
		return _('When the company that issued the subscription is told was not stated.');
	},

	esimPlanReasonText: function(token) {
		switch (token) {
		case 'endpoint-unproven':
			return _('this eUICC’s own identifier has never been read');
		case 'lpa-unavailable':
			return _('the software that talks to eUICCs is not installed');
		case 'requires-slot-change':
			return _('this eUICC is in a slot that is not in use');
		case 'no':
			return _('this eUICC cannot be reached on this router');
		}
		return token || _('the reason was not given');
	},

	/* ---- renaming ---- */

	openNicknameDialog: function(subject, endpoint, profile) {
		var self = this;
		if (self.subjectBusy(subject))
			return;
		self.nicknameInput = E('input', { 'type': 'text', 'class': 'cbi-input-text',
			'data-apn-control': 'esim-nickname',
			'value': profile.nickname || '' }, []);
		var dialog = E('div', { 'class': 'apn-nickname-dialog' }, [
			E('p', {}, [
				_('A name of your own for the subscription ending %s. It is stored on the eUICC and is only ever shown to you.')
					.format(suffixLabel(profile.iccid_suffix))
			]),
			table([ row(_('Name'), self.nicknameInput) ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'type': 'button', 'data-apn-nav': 'cancel',
					'click': function() { ui.hideModal(); self.closeDialog(); } }, [ _('Cancel') ]),
				' ',
				E('button', { 'class': 'btn cbi-button-action important', 'type': 'button',
					'data-apn-nav': 'confirm',
					'click': function() {
						var value = self.nicknameInput && self.nicknameInput.value || '';
						ui.hideModal();
						self.closeDialog();
						self.nicknameInput = null;
						self.startEsimSecretAction(subject, endpoint, 'nickname', function() {
							return callEsimNickname(subject.modem.modem_id,
								endpoint.endpoint_id, profile.profile_id, value);
						});
					} }, [ _('Rename') ])
			])
		]);
		self.openDialog(_('Rename this subscription'), dialog);
	},

	/* ---- adding a subscription ---- */

	/* An activation code is a secret: it is worth the subscription it buys, and
	 * an unbound one can be redeemed on somebody else's eUICC. It travels in
	 * the request environment and never in the arguments, is cleared from the
	 * page when the call returns whether it succeeded or not, is never stored,
	 * never put in the address or the history, and never displayed back -- not
	 * to confirm it and not inside an error. */
	/* ---- reading a code out of a picture ----
	 *
	 * The decoder is carried by this package and loaded from this router, not
	 * from anywhere else: the machine being configured may have no internet at
	 * the moment somebody is configuring it, which is rather the point. It is
	 * a quarter of a megabyte, so it is fetched the first time somebody
	 * chooses a picture and never on page load -- the page is measured in
	 * hundreds of milliseconds and this would be most of a second of it, spent
	 * for the many visits that never open this dialog.
	 *
	 * The picture never leaves the browser. There is no upload here and no
	 * request carrying it: it is drawn to a canvas, the pixels are read, and
	 * what comes out is text. */
	qrDecoderPromise: function() {
		var self = this;
		if (self.qrDecoder)
			return self.qrDecoder;
		var host = browserWindow();
		if (!host || !host.document || typeof host.document.createElement !== 'function')
			return Promise.reject(new Error(_('This browser cannot read pictures.')));
		if (typeof host.jsQR === 'function') {
			self.qrDecoder = Promise.resolve(host.jsQR);
			return self.qrDecoder;
		}
		self.qrDecoder = new Promise(function(resolve, reject) {
			var script = host.document.createElement('script');
			/* Relative to LuCI's own resource base, which is where this
			 * package installs it. */
			script.src = qrDecoderUrl();
			script.onload = function() {
				if (typeof host.jsQR === 'function')
					resolve(host.jsQR);
				else
					reject(new Error(_('The QR reader on this router did not load.')));
			};
			script.onerror = function() {
				reject(new Error(_('The QR reader on this router could not be loaded.')));
			};
			host.document.head.appendChild(script);
		}).catch(function(error) {
			/* A failed load is not remembered as a decoder: the next attempt
			 * asks again rather than failing for ever on one bad fetch. */
			self.qrDecoder = null;
			throw error;
		});
		return self.qrDecoder;
	},

	/* One picture, turned into pixels. Browser plumbing and nothing else, kept
	 * apart from the decisions above and below it so that both of those can be
	 * reasoned about -- and tested -- without a canvas.
	 *
	 * The object URL is revoked as soon as the image has been drawn, on every
	 * path including failure, and no copy of the picture is kept anywhere. */
	imageDataFromFile: function(file) {
		var host = browserWindow();
		if (!file || !host || !host.URL || typeof host.URL.createObjectURL !== 'function')
			return Promise.reject(new Error(_('That file could not be read.')));
		return new Promise(function(resolve, reject) {
			var url = host.URL.createObjectURL(file);
			var image = new host.Image();
			var done = function(fn, value) {
				host.URL.revokeObjectURL(url);
				fn(value);
			};
			image.onload = function() {
				try {
					/* Bounded, because a modern phone photograph is twelve
					 * megapixels and scanning all of it would lock the tab for
					 * seconds to no benefit: a QR that needs more than this to
					 * resolve is a QR too small in the frame to read anyway. */
					var longest = Math.max(image.width, image.height) || 1;
					var scale = longest > 1600 ? 1600 / longest : 1;
					var width = Math.max(1, Math.round(image.width * scale));
					var height = Math.max(1, Math.round(image.height * scale));
					var canvas = host.document.createElement('canvas');
					canvas.width = width;
					canvas.height = height;
					var context = canvas.getContext('2d');
					context.drawImage(image, 0, 0, width, height);
					done(resolve, context.getImageData(0, 0, width, height));
				} catch (error) {
					done(reject, new Error(_('That picture could not be read.')));
				}
			};
			image.onerror = function() {
				done(reject, new Error(_('That file is not a picture this browser can open.')));
			};
			image.src = url;
		});
	},

	readCodeFromPicture: function(file) {
		var self = this;
		if (!file)
			return Promise.resolve();
		self.setPictureNote(_('Reading the picture…'));
		return self.qrDecoderPromise().then(function(decode) {
			return self.imageDataFromFile(file).then(function(pixels) {
				var found = decode(pixels.data, pixels.width, pixels.height);
				return found && found.data ? String(found.data) : null;
			});
		}).then(function(text) {
			if (text === null) {
				self.setPictureNote(_('No QR code was found in that picture. A closer, straighter photo usually works.'));
				return;
			}
			self.applyDecodedCode(text);
		}).catch(function(error) {
			self.setPictureNote(error.message);
		});
	},

	/* What a decoded picture turns into. A QR may hold anything at all -- a
	 * web address, a wifi password, somebody's business card -- so what came
	 * out of one is put through exactly the same check a typed code is, and
	 * the field is filled only if it passes.
	 *
	 * The code itself is never shown back, here or in any message. It is put
	 * into a field that does not display what it holds, and the confirmation
	 * names the provider address instead: enough to see that the right picture
	 * was read, and not enough to be worth a screenshot. */
	applyDecodedCode: function(text) {
		var self = this;
		var parsed = activationCode(text);
		if (!parsed.ok) {
			self.setPictureNote(_('That QR code is not an activation code. %s').format(parsed.why));
			return false;
		}
		if (self.downloadCode)
			self.downloadCode.value = parsed.code;
		self.setPictureNote(_('Read a subscription from %s. Check it is the right provider, then add it.')
			.format(activationCodeHost(parsed.code)));
		return true;
	},

	setPictureNote: function(message) {
		if (this.downloadPictureNote)
			this.downloadPictureNote.textContent = message;
	},

	openDownloadDialog: function(subject, endpoint) {
		var self = this;
		if (self.subjectBusy(subject))
			return;
		self.downloadCode = E('input', { 'type': 'password', 'class': 'cbi-input-password',
			'data-apn-control': 'esim-download',
			'placeholder': _('the code your provider gave you') }, []);
		self.downloadConfirmation = E('input', { 'type': 'password',
			'class': 'cbi-input-password', 'data-apn-control': 'esim-download' }, []);
		self.downloadMatching = E('input', { 'type': 'password',
			'class': 'cbi-input-password', 'data-apn-control': 'esim-download' }, []);
		/* Some providers hand out a QR and nothing else, and reading one back
		 * into text needs a scanner, a second device and the knowledge that a
		 * QR contains text at all. None of that is a reasonable thing to
		 * require of somebody adding a subscription.
		 *
		 * A file input and not a camera stream. `getUserMedia` needs a secure
		 * context and LuCI over plain HTTP on a LAN address is not one, so an
		 * in-page scanner would simply not work on the router this is for. A
		 * file input costs nothing and does more: on a phone the browser's own
		 * camera opens from it, so a QR on paper is photographed straight into
		 * the form, and on a desktop it takes the picture the provider
		 * emailed. */
		self.downloadPicture = E('input', { 'type': 'file', 'accept': 'image/*',
			/* Not a catalogue control: it is a field inside the download
			 * control's dialog, and giving it a catalogue id would claim a row
			 * the contract does not have. */
			'data-apn-field': 'qr-picture',
			'change': function(event) {
				var files = event && event.target && event.target.files;
				self.readCodeFromPicture(files && files[0]);
			} }, []);
		self.downloadPictureNote = E('p', { 'class': 'apn-area-note' }, []);

		self.downloadDialog = E('div', { 'class': 'apn-download-dialog' }, [
			E('p', {}, [
				_('Your provider gives you an activation code, usually printed under a QR code. Paste it exactly as you were given it — with or without the LPA: at the front, and spaces do not matter. It is worth the subscription it buys: anyone who has it can use it once, so it is sent to the modem without ever being written down on this router.')
			]),
			E('p', {}, [
				_('The download interrupts the connection on %s while it runs, and this page follows it.')
					.format(subject.section || '')
			]),
			E('p', {}, [
				_('It also needs the Internet while that connection is down, so if this modem is the router’s only way out it is refused rather than started.')
			]),
			table([
				row(_('Activation code'), self.downloadCode),
				row(_('Or a picture of the QR code'), self.downloadPicture,
					_('A photo, a screenshot, or the image your provider sent. It is read here in your browser and is never uploaded anywhere.')),
				row(_('Confirmation code'), self.downloadConfirmation,
					_('Only if your provider gave you one. Most do not.')),
				row(_('Matching ID'), self.downloadMatching,
					_('Only if your provider asked you for one separately.'))
			]),
			self.downloadPictureNote,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'type': 'button', 'data-apn-nav': 'cancel',
					'click': function() { self.closeDownloadDialog(); } }, [ _('Cancel') ]),
				' ',
				E('button', { 'class': 'btn cbi-button-action important', 'type': 'button',
					'data-apn-nav': 'confirm',
					'click': function() { self.confirmDownload(subject, endpoint); } },
					[ _('Add this subscription') ])
			])
		]);
		self.openDialog(_('Add a subscription'), self.downloadDialog);
	},

	closeDownloadDialog: function() {
		/* Overwritten, then detached, and no reference kept in anything that
		 * outlives the handler. */
		if (this.downloadCode)
			this.downloadCode.value = '';
		if (this.downloadConfirmation)
			this.downloadConfirmation.value = '';
		if (this.downloadMatching)
			this.downloadMatching.value = '';
		/* The chosen file goes too. A file input holds a handle to something on
		 * the person's disk, and there is no reason for one to outlive the
		 * dialog that asked for it. */
		if (this.downloadPicture)
			this.downloadPicture.value = '';
		if (this.downloadDialog)
			dom.content(this.downloadDialog, []);
		this.downloadCode = null;
		this.downloadConfirmation = null;
		this.downloadMatching = null;
		this.downloadPicture = null;
		this.downloadPictureNote = null;
		this.downloadDialog = null;
		ui.hideModal();
		this.closeDialog();
	},

	confirmDownload: function(subject, endpoint) {
		var self = this;
		var values = {
			code: self.downloadCode && self.downloadCode.value || '',
			confirmation: self.downloadConfirmation && self.downloadConfirmation.value || '',
			matching: self.downloadMatching && self.downloadMatching.value || ''
		};
		/* Read here, so that a value that cannot be a code never becomes an
		 * operation. The message never echoes what was typed: a code is worth
		 * the subscription it buys, and an error is the easiest place for one
		 * to end up in a screenshot. */
		var parsed = activationCode(values.code);
		if (!parsed.ok) {
			ui.addNotification(null, E('p', {}, [ parsed.why ]), 'warning');
			return;
		}
		var request = {
			modem: subject.modem.modem_id,
			endpoint: endpoint.endpoint_id,
			activation_code: parsed.code,
			confirmation_code: values.confirmation.trim(),
			matching_id: values.matching.trim(),
			allow_unverified: self.downloadAllowUnverified === true
		};

		self.closeDownloadDialog();
		self.downloadAllowUnverified = false;
		values.code = '';
		values.confirmation = '';
		values.matching = '';
		return self.startEsimSecretAction(subject, endpoint, 'download', function() {
			return callEsimDownload(request.modem, request.endpoint, request.activation_code,
				request.confirmation_code, request.matching_id, request.allow_unverified);
		});
	},

	/* The one downgrade this project permits, and the only failure it is
	 * permitted for. The consent has to say what is actually at risk, which is
	 * not "a harmless code": an unbound activation code and the subscription it
	 * was bought for can be intercepted and redeemed on another eUICC. */
	offerUnverifiedRetry: function(subject, endpoint, action, args) {
		var self = this;
		self.showConfirmation(_('Try again without verifying the provider'),
			_('This router could not verify that it is talking to your provider, only that something answered at that address.'),
			[ E('p', {}, [
				_('Going ahead anyway means an activation code and the subscription you paid for could be taken by whatever answered, and used on somebody else’s eUICC.')
			]), E('p', {}, [
				_('This applies to this one attempt only. Nothing is remembered and nothing else on this router is changed.')
			]) ], true, function() {
				if (action === 'download') {
					/* The code was never kept, which is the point, so this
					 * reopens the form. The consent travels with the attempt
					 * that form starts. */
					self.downloadAllowUnverified = true;
					self.openDownloadDialog(subject, endpoint);
					return;
				}
				self.startEsimAction(subject, endpoint, action,
					args.concat([ '--allow-unverified' ]), {}, true);
			});
	},

	/* ---- the messages waiting on the card ---- */

	/* A deferred message has exactly two buttons: send it again, and discard
	 * it. There is deliberately no automatic retry -- sweeping a backlog into
	 * somebody else's inhibit would add sixteen to twenty seconds per message
	 * to an operation whose length the user was quoted in advance -- so this
	 * page is where a stuck message becomes visible and actionable, and it is
	 * the only place it can be. */
	notificationControlNodes: function(subject, endpoint, notification) {
		var self = this;
		var caps = endpoint.capabilities || null;
		var send = caps ? gate(caps.notification_send) : 'unknown';
		var remove = caps ? gate(caps.notification_remove) : 'unknown';
		var buttons = [];

		if (send === 'yes')
			buttons.push(self.control('esim-notif-send', _('Send it now'), 'cbi-button-action',
				function() { self.confirmNotificationSend(subject, endpoint, notification); },
				{ busy: self.subjectBusy(subject) }));
		if (remove === 'yes')
			buttons.push(self.control('esim-notif-remove', _('Discard it'), 'cbi-button-remove',
				function() { self.confirmNotificationRemove(subject, endpoint, notification); },
				{ busy: self.subjectBusy(subject) }));
		if (!buttons.length)
			return [];
		return [ E('div', { 'class': 'apn-button-row' }, buttons) ];
	},

	confirmNotificationSend: function(subject, endpoint, notification) {
		var self = this;
		if (self.subjectBusy(subject))
			return;
		self.showConfirmation(_('Send it now'),
			_('This sends the message the eUICC is holding to %s. It stays on the card until that company has taken it.')
				.format(text(notification.address)),
			[ E('p', {}, [
				_('The connection is interrupted while it happens, and the message is removed from the card only once it has been taken.')
			]), E('p', {}, [
				_('It needs the Internet while that connection is down, so if this modem is the router’s only way out it is refused rather than started.')
			]), E('p', { 'class': 'apn-confirm-scope' }, [
				_('This runs against %s only.').format(subject.section || '')
			]) ], false, function() {
				self.startEsimAction(subject, endpoint, 'notification-send',
					[ String(notification.sequence) ], {}, true);
			});
	},

	confirmNotificationRemove: function(subject, endpoint, notification) {
		var self = this;
		if (self.subjectBusy(subject))
			return;
		self.showConfirmation(_('Discard it'),
			_('This removes the message from the eUICC without sending it. %s will never learn about the change it describes.')
				.format(text(notification.address)),
			[ E('p', {}, [
				_('There is no way to get it back afterwards. If the change was a subscription being added or removed, the company that issued it will keep its own idea of what you have.')
			]), E('p', { 'class': 'apn-confirm-scope' }, [
				_('This runs against %s only.').format(subject.section || '')
			]) ], true, function() {
				/* The wrapper refuses this verb without the confirmation, so
				 * the consent is a value the operation carries rather than a
				 * thing this page merely displayed. */
				self.startEsimAction(subject, endpoint, 'notification-remove',
					[ String(notification.sequence), '--confirm-discard' ], {}, true);
			});
	},

	/* ---- removing a subscription ---- */

	/* The only irreversible operation in the suite. This dialog is a courtesy
	 * on top of a backend protocol, and it never becomes the guarantee: the
	 * backend mints a single-use, deadlined token bound to this exact profile,
	 * and a confirm without a live one is refused whatever this page shows.
	 *
	 * The token itself never enters the browser. The plan comes back without
	 * it and the mutating wrapper resolves it from the root-only record by the
	 * operation id, so a page that is compromised holds nothing that deletes a
	 * subscription. */
	openDeleteFlow: function(subject, endpoint, profile) {
		var self = this;
		if (self.subjectBusy(subject))
			return;
		self.esimClearRefusal(endpoint);

		/* Planning reads the card, and on this hardware reading the card means
		 * taking the modem from ModemManager. That outage happens before any
		 * confirmation dialog exists, so it is consented to first and on its
		 * own -- with the number from `read-takeover-plan`, because the plan's
		 * own `plan_takeover_seconds` only arrives once the outage has already
		 * been paid. */
		if (endpoint.reachable === 'yes')
			return self.planDeletion(subject, endpoint, profile, false);

		return callPlan(esimQueryCommand,
			[ 'read-takeover-plan', subject.modem.modem_id, endpoint.endpoint_id ]
		).then(function(plan) {
			if (plan.available !== true) {
				self.esimRefuse(endpoint, self.takeoverRefusalText(plan));
				return;
			}
			var bound = durationLabel(plan.worst_case_seconds);
			self.showConfirmation(_('Look at this subscription first'),
				_('Before anything can be removed, this eUICC has to be read, and reading it interrupts the connection on %s.')
					.format(plan.interrupts_interface || subject.section || ''),
				[ E('p', {}, [ bound
					? _('That read takes up to %s. Nothing is removed by it, and you are asked again afterwards.')
						.format(bound)
					: _('Nothing is removed by that read, and you are asked again afterwards.') ]),
					E('p', { 'class': 'apn-confirm-scope' }, [
						_('This runs against %s only.').format(subject.section || '')
					]) ],
				false, function() {
					self.planDeletion(subject, endpoint, profile, true);
				});
		}).catch(function(error) {
			self.esimRefuse(endpoint,
				_('What reading this eUICC would interrupt could not be established, so a removal is not offered: %s')
					.format(error.message));
		});
	},

	/* Started and followed, never awaited.
	 *
	 * Measured on the FM350-GL 2026-09-03: a plan that runs to the end reads
	 * the card, which took 24 seconds against the 20 LuCI gives an RPC. The
	 * request timed out, the page said so honestly, and a deletion was
	 * unreachable on that modem -- while the RM520N-GL's faster card had
	 * hidden it since C5. So the plan is a job like every other long thing
	 * here, and this waits for it the same way the switch does. */
	planDeletion: function(subject, endpoint, profile, allowTakeover) {
		var self = this;
		var extra = [ profile.profile_id ];
		if (allowTakeover)
			extra.push('--allow-takeover');
		if (!self.esimPlanWanted)
			self.esimPlanWanted = {};
		/* What to do with the plan once the job has produced one. It is kept
		 * beside the pending operation rather than in a closure so that a
		 * rebuilt page follows an operation it did not start without also
		 * opening a dialog nobody asked for. */
		self.esimPlanWanted[subject.modem.modem_id] = {
			subjectKey: subject.key, endpointId: endpoint.endpoint_id,
			profileId: profile.profile_id
		};
		return self.startEsimAction(subject, endpoint, 'delete-plan', extra, {}, false);
	},

	/* The document the job produced, read once it is finished — and read for
	 * *this* operation, which is the whole safety of it.
	 *
	 * The backend stores one plan per modem. Asking it only which modem and
	 * which eUICC is not a question with one answer: an earlier plan for a
	 * different subscription answers it just as well. On 2026-09-04 one did.
	 * A plan job died two seconds in without writing anything, this read
	 * returned the previous day's plan for another subscription, and the
	 * confirmation dialog was built around it -- naming a subscription nobody
	 * had asked to remove. So the operation id goes with the question, and the
	 * backend refuses a document belonging to any other.
	 *
	 * The profile is checked here as well. The backend's binding should make
	 * this impossible; it is checked anyway, because the check costs nothing
	 * and being wrong costs somebody their subscription. */
	collectDeletePlan: function(subject, endpoint, action, wanted) {
		var self = this;
		var operationId = action && action.operation_id ? String(action.operation_id) : '';
		if (!operationId) {
			self.esimRefuse(endpoint,
				_('The removal could not be planned, so nothing was done: the operation did not say which plan it made.'));
			return Promise.resolve();
		}
		return callPlan(esimQueryCommand, [ 'delete-plan-result',
			subject.modem.modem_id, endpoint.endpoint_id, operationId ]).then(function(plan) {
			if (plan.available !== true) {
				self.esimRefuse(endpoint, self.deletePlanRefusalText(plan));
				return;
			}
			/* Last line of defence, and it opens nothing when it fails. */
			if (wanted && wanted.profileId && plan.profile_id !== wanted.profileId) {
				self.esimRefuse(endpoint,
					_('The plan that came back is for a different subscription than the one you asked about, so nothing is offered for removal. Ask again.'));
				return;
			}
			self.showDeleteDialog(subject, endpoint, plan);
		}).catch(function(error) {
			self.esimRefuse(endpoint,
				_('The removal could not be planned, so nothing was done: %s').format(error.message));
		});
	},

	deletePlanRefusalText: function(plan) {
		switch (plan.refusal_reason) {
		case 'profile_enabled':
			return _('This subscription is in use, and one in use is never removed. Stop using it first.');
		case 'profile_in_use':
			return _('This subscription is the one this router is connected with, so it is not removed.');
		case 'in_use_unknown':
			return _('Whether this subscription is the one the router is using could not be established, and an open question about something irreversible is a stop rather than a guess.');
		case 'profile_ambiguous':
			return _('More than one subscription on this card answers to that identity, so none of them is removed.');
		case 'profile_state_unknown':
			return _('This subscription’s state could not be read, so it is not removed.');
		case 'other_operation':
			return _('The plan that came back belongs to a different request than the one you made, so nothing is offered for removal. Ask again.');
		case 'no_plan':
			return _('The preparation did not finish, so there is no plan to confirm. Nothing was changed; ask again.');
		case 'other_endpoint':
			return _('The plan that came back belongs to a different eUICC, so nothing is offered for removal.');
		case 'endpoint_unproven':
			return _('This eUICC’s own identifier has never been read, so nothing on it may be removed.');
		case 'endpoint_unreachable':
			return _('This eUICC cannot be reached, so nothing on it may be removed.');
		case 'modem_busy':
			return _('Another operation is holding this modem. Plan the removal again when it has finished.');
		case 'takeover_required':
			return _('Reading the card for this removal needs the modem interrupted, and that was not agreed to.');
		case 'lpa_unavailable':
			return _('The software that talks to eUICCs is not installed.');
		case 'identity_incomplete':
			return _('Something the plan would have to bind could not be read, so no plan was issued.');
		case 'read_abandoned':
			return _('The card could not be read in time, so no plan was issued.');
		case 'no_control_port':
			return _('No way of talking to the card could be found after the modem was taken over.');
		case 'token_unwritable':
		case 'no_clock':
			return _('This router could not record a plan that expires, so no removal is offered.');
		}
		return _('The removal was refused: %s').format(plan.refusal_reason || _('the reason was not given'));
	},

	/* Which subscription this is, in the words somebody would use for it. */
	deleteSubjectSentence: function(profile) {
		var name = profile.nickname || this.profileProviderLabel(profile);
		if (profile.state === 'enabled')
			return _('You are about to remove %s — the subscription this modem is using right now.')
				.format(name);
		return _('You are about to remove %s. It is not the subscription this modem is using.')
			.format(name);
	},

	/* Whether anything else on this card looks the same, which is what decides
	 * whether the four digits are a formality or the only thing that tells two
	 * subscriptions apart. Saying which it is turns the typing from a hoop into
	 * a check the person can actually make. */
	profileSiblings: function(endpoint, profile) {
		var self = this;
		var card = self.esimCard(endpoint);
		var profiles = card && card.profiles && Array.isArray(card.profiles.profiles)
			? card.profiles.profiles : [];
		var name = profile.nickname || self.profileProviderLabel(profile);
		var alike = profiles.filter(function(other) {
			return (other.nickname || self.profileProviderLabel(other)) === name;
		});
		if (alike.length > 1)
			return {
				note: _('This eUICC holds %s subscriptions that all look like “%s”. The last four digits are the only thing that tells them apart.')
					.format(String(alike.length), name),
				why: _('Type the last four digits shown above. On this card they are the only thing that tells your subscriptions apart, so this is the check.')
			};
		return {
			note: null,
			why: _('Type the last four digits shown above. Nothing else on this card is called “%s”, so this is here to make sure the removal is deliberate.')
				.format(name)
		};
	},

	showDeleteDialog: function(subject, endpoint, plan) {
		var self = this;
		var profile = plan.profile || {};
		var suffix = String(profile.iccid_suffix || '');
		/* Shown as a live number rather than as a sentence fixed at the moment
		 * the dialog opened. The plan binds the card as it was read, and how
		 * much of that binding is left is a fact that changes while the dialog
		 * is on screen -- so it is the one number here that has to move.
		 *
		 * Its budget grew to 300 seconds on 2026-09-03 because planning became
		 * a job and now spends part of it on itself. Not because reading this
		 * dialog takes long: a person deleting a subscription is sitting in
		 * front of the one they just opened. */
		var remaining = parseInt(plan.expires_in_seconds, 10);
		if (!(remaining > 0))
			remaining = 0;
		var expiry = durationLabel(plan.expires_in_seconds);
		var countdown = E('span', { 'data-apn-plan-remaining': String(remaining) },
			[ remaining > 0 ? durationLabel(remaining) : _('no time at all') ]);
		/* Empty until it has something to say, so that a dialog that is still
		 * usable carries no warning about not being usable. */
		var expired = E('p', { 'class': 'apn-area-note' }, []);

		/* Typed back, and compared exactly. The control is inert until it
		 * matches, and it is never the control the keyboard lands on. */
		/* The handlers go in the attributes, because that is what makes them
		 * listeners. Assigning `node.keyup` after the node exists sets a
		 * property in a real browser and fires nothing -- and a node stub that
		 * models attributes as properties cannot tell the two apart, which is
		 * exactly the class of defect a fixture cannot see. */
		var confirm = null;
		function matchTyped() {
			if (confirm)
				confirm.disabled = (typed.value || '').trim() !== suffix;
		}
		var typed = E('input', { 'type': 'text', 'class': 'cbi-input-text',
			'data-apn-control': 'esim-delete', 'placeholder': suffix.replace(/./g, '0'),
			'keyup': matchTyped, 'change': matchTyped, 'input': matchTyped }, []);
		confirm = E('button', {
			'class': 'btn cbi-button-remove important',
			'type': 'button',
			'data-apn-nav': 'confirm',
			'click': function() {
				if (confirm.disabled)
					return;
				ui.hideModal();
				self.closeDialog();
				self.startEsimAction(subject, endpoint, 'delete-confirm',
					[ plan.operation_id ], {}, true);
			}
		}, [ _('Delete this subscription') ]);
		confirm.disabled = true;

		var rows = [
			row(_('Provider'), self.profileProviderLabel(profile)),
			row(_('Subscription identifier'), suffixLabel(suffix)),
			row(_('Modem'), self.modemModelLabel(subject.modem || {})),
			row(_('Slot'), endpoint.slot != null ? String(endpoint.slot) : _('could not be determined'))
		];
		if (profile.nickname)
			rows.splice(1, 0, row(_('Name you gave it'), profile.nickname));

		/* What the person actually knows about this subscription, said first
		 * and in their words. An identifier is not how anybody holds a
		 * subscription in mind -- "the Vodafone one", "the one I called work"
		 * is -- so the dialog opens with that and keeps the identifier as the
		 * supporting detail it is. */
		var siblings = self.profileSiblings(endpoint, profile);
		self.openDialog(_('Delete this subscription'),
			E('div', { 'class': 'apn-delete-dialog' }, [
				E('p', { 'class': 'apn-delete-subject' }, [ self.deleteSubjectSentence(profile) ]),
				E('p', {}, [
					_('This removes the subscription from the eUICC. It cannot be undone, and your operator may not let you download it again — for many operators one activation code works once.')
				]),
				siblings.note ? E('p', { 'class': 'apn-area-note' }, [ siblings.note ]) : E('span', {}, []),
				table(rows),
				E('p', {}, expiry
					? [ _('This plan was made against the card as it is now and stops being valid in '),
						countdown,
						_('. After that you are asked to plan again.') ]
					: [ _('This plan was made against the card as it is now.') ]),
				/* The second of the plan's two durations, and the one the
				 * person is still able to decline. The first -- what reading
				 * the card for this plan cost -- has already been paid by the
				 * time anybody reads this, and was named before it was. */
				E('p', {}, [ durationLabel(plan.worst_case_seconds)
					? _('The removal itself takes the modem away for up to %s.')
						.format(durationLabel(plan.worst_case_seconds))
					: _('How long the removal holds the modem was not stated.') ]),
				E('p', {}, [ siblings.why ]),
				table([ row(_('Last four digits'), typed) ]),
				E('p', { 'class': 'apn-confirm-scope' }, [
					_('This runs against this one subscription on this one eUICC.')
				]),
				expired,
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'type': 'button', 'data-apn-nav': 'cancel',
						'click': function() { ui.hideModal(); self.closeDialog(); } }, [ _('Cancel') ]),
					' ',
					confirm
				])
			]));

		/* Once the plan is out of time the confirmation cannot succeed:
		 * `delete-confirm` refuses a spent plan with `token_expired`. Saying
		 * so here, and taking the control away, is the difference between a
		 * dialog that stops working and one that explains why. Nothing is
		 * re-planned automatically -- a fresh plan means reading the card
		 * again, and that is a thing a person asks for. */
		/* Asked of the window the dialog is in, and not of a bare global. The
		 * countdown is a browser affordance: where there is no window there is
		 * no clock to run, and a page rendered outside one shows the number
		 * the plan gave and nothing that ticks. */
		/* A plan with nothing left is refused by `delete-confirm`, so the
		 * dialog says so at once rather than letting somebody type four digits
		 * into a control that cannot work. It happens without any clock: a
		 * plan read late enough arrives expired. */
		if (remaining <= 0) {
			confirm.disabled = true;
			typed.disabled = true;
			expired.textContent = _('This plan has run out of time and cannot be used. Close this and ask for the removal again; the card will be read afresh.');
		}
		var clockHost = browserWindow();
		if (remaining > 0 && clockHost && typeof clockHost.setInterval === 'function') {
			var deadline = Date.now() + (remaining * 1000);
			self.planCountdownHost = clockHost;
			self.planCountdown = clockHost.setInterval(function() {
				var left = Math.round((deadline - Date.now()) / 1000);
				if (!self.dialogContainer) {
					self.stopPlanCountdown();
					return;
				}
				if (left > 0) {
					countdown.setAttribute('data-apn-plan-remaining', String(left));
					countdown.textContent = durationLabel(left);
					return;
				}
				self.stopPlanCountdown();
				countdown.setAttribute('data-apn-plan-remaining', '0');
				countdown.textContent = _('no time at all');
				confirm.disabled = true;
				typed.disabled = true;
				expired.textContent = _('This plan has run out of time and cannot be used. Close this and ask for the removal again; the card will be read afresh.');
			}, 1000);
		}
	},

	/* ---- eSIM operations ---- */

	/* The eSIM package runs its own coordinator, with its own state directory
	 * and its own `action-status`. It is a second operation model only in
	 * where it is stored: the shape is the modem coordinator's, and this page
	 * treats it the same way -- start, then follow, and never invent a result
	 * for a launch answer that was lost. */
	startEsimAction: function(subject, endpoint, verb, extraArgs, env, follow) {
		var self = this;
		var modemId = subject.modem.modem_id;
		self.setControlsBusy(true);
		if (!self.esimPending)
			self.esimPending = {};
		self.esimPending[modemId] = {
			endpointId: endpoint.endpoint_id, action: verb, follow: !!follow,
			subjectKey: subject.key, waited: 0
		};
		self.esimPollPending = true;
		self.esimClearRefusal(endpoint);
		var args = (verb === 'card-probe' ? [ verb, modemId ] :
			[ verb, modemId, endpoint.endpoint_id ]).concat(extraArgs || []);
		return call(esimControlCommand, args, env || {}).then(function(result) {
			if (!result.accepted && !result.busy)
				throw new Error(result.message || _('The operation could not be started'));
		}).catch(function(error) {
			/* As everywhere else on this page: the answer may have been lost
			 * after the job was accepted, so this reports the error and keeps
			 * polling rather than deciding what happened. */
			ui.addNotification(null, E('p', {}, [ error.message ]), 'error');
		}).then(function() {
			if (!self.userEditing)
				self.renderRoute();
		});
	},

	/* The same operation, started through the channel a secret can take.
	 *
	 * It is a separate method rather than a flag on the one above because the
	 * two differ in the only way that matters here: this one never builds an
	 * argument vector out of the value it is carrying, and there is nothing in
	 * it that could be made to. */
	startEsimSecretAction: function(subject, endpoint, verb, invoke) {
		var self = this;
		var modemId = subject.modem.modem_id;
		self.setControlsBusy(true);
		if (!self.esimPending)
			self.esimPending = {};
		self.esimPending[modemId] = {
			endpointId: endpoint.endpoint_id, action: verb, follow: true,
			subjectKey: subject.key, waited: 0
		};
		self.esimPollPending = true;
		self.esimClearRefusal(endpoint);
		return invoke().then(secretResult).then(function(result) {
			if (!result.accepted && !result.busy)
				throw new Error(result.message || _('The operation could not be started'));
		}).catch(function(error) {
			/* As everywhere else: a lost answer keeps polling rather than
			 * deciding what happened. */
			ui.addNotification(null, E('p', {}, [ error.message ]), 'error');
		}).then(function() {
			if (!self.userEditing)
				self.renderRoute();
		});
	},

	/* Runs only while something is pending, exactly as the modem document
	 * refresh beside it does. It reads the coordinator's own state and reaches
	 * no card: `action-status` opens nothing, which is what makes it safe to
	 * ask on a timer at all. */
	refreshEsimOperation: function() {
		var self = this;
		var ids = Object.keys(self.esimPending || {});
		if (!ids.length) {
			self.esimPollPending = false;
			return Promise.resolve();
		}
		return self.sequence(ids.map(function(modemId) {
			return function() { return self.refreshEsimOperationFor(modemId); };
		}));
	},

	refreshEsimOperationFor: function(modemId) {
		var self = this;
		/* A document and a non-zero exit are both possible here, so the answer
		 * is read as a document first. */
		return callPlan(esimQueryCommand, [ 'action-status', modemId ]).then(function(action) {
			if (!self.documents.esimAction)
				self.documents.esimAction = {};
			self.documents.esimAction[modemId] = action;
			var pending = (self.esimPending || {})[modemId];
			if (!pending)
				return;
			if (action.busy === true) {
				pending.started = true;
				if (!self.userEditing)
					self.renderRoute();
				return;
			}
			/* Not busy, and this operation has not been seen running yet. The
			 * launch may still be in flight, so a few cycles are given before
			 * concluding that nothing was started -- the same shape the engine
			 * poll beside it uses. */
			if (!pending.started) {
				pending.waited = (pending.waited || 0) + 1;
				if (pending.waited < 5)
					return;
			}
			delete self.esimPending[modemId];
			self.esimPollPending = Object.keys(self.esimPending).length > 0;
			self.setControlsBusy(false);
			return self.afterEsimOperation(modemId, pending, action);
		}).catch(function() {
			/* A transient polling failure is not evidence that a long-running
			 * operation ended. */
		});
	},

	/* What happens once the modem has been handed back.
	 *
	 * Measured on the reference router: for seven to thirteen seconds after an
	 * operation releases its inhibit the endpoint cannot be resolved at all,
	 * because ModemManager is still re-enumerating the modem it has just been
	 * given back. A page that reads the instant the operation finishes gets a
	 * refusal rather than a list, so this waits for the endpoint to come back
	 * before it reads anything, on a bounded budget, and says so if it does
	 * not. */
	afterEsimOperation: function(modemId, pending, action) {
		var self = this;
		/* `partial` is read here exactly as `succeeded` is, and the reason is
		 * what `partial` means: part of the change was made. A switch-on whose
		 * connection never came back has still enabled the profile -- the
		 * terminal message says so in as many words -- so the card this page
		 * is holding is the one from before the change.
		 *
		 * Found on the FM350-GL 2026-09-03. The list kept saying "not in use"
		 * for a profile the card reported `enabled`, beside a banner saying
		 * the change was made; and because the list drives the controls, the
		 * page offered "Use this one" for a subscription that was already in
		 * use and hid the way to switch it off. A stale reading of a card is
		 * worse than no reading: it is the page asserting something untrue
		 * about hardware the user cannot see.
		 *
		 * A clean refusal changes nothing and needs no read. `pending.follow`
		 * still gates all of it, so this buys no card session the user did not
		 * already agree to. */
		var terminal = self.esimTerminalClass(action && action.status);
		var mayHaveChanged = terminal === 'succeeded' || terminal === 'partial';
		var key = pending.endpointId || '';
		if (!self.esimCardPending)
			self.esimCardPending = {};
		if (pending.follow && mayHaveChanged && key)
			self.esimCardPending[key] = true;
		/* Modem-keyed, because the area that needed it has no endpoint to key
		 * by: not having one is the whole state it is rendering. It is set
		 * before the wait and cleared on both of its ends. */
		if (!self.esimSettling)
			self.esimSettling = {};
		self.esimSettling[modemId] = true;
		if (!self.userEditing)
			self.renderRoute();
		return self.waitForEndpoint(modemId, pending.endpointId).then(function(endpoint) {
			/* A plan is the one operation whose whole product is a document.
			 * It changed nothing on the card, so there is nothing to re-read;
			 * what there is, is a plan to fetch and a dialog to open -- or the
			 * refusal the worker recorded instead. */
			/* What this router has tried is the half of "was it sent?" that the
			 * card cannot answer. Under SGP.22 a notification stays until the
			 * issuer takes it, so everything still listed is by definition not
			 * taken -- and a message sent four times looks exactly like one
			 * nobody has touched. The attempt is known here and nowhere else,
			 * so it is kept here. It is deliberately not persisted: a page that
			 * has been reloaded does not know, and must not claim to. */
			if (pending.action === 'notification-send' && mayHaveChanged && key) {
				var seq = action && action.sequence;
				if (seq !== null && seq !== undefined && seq !== '') {
					if (!self.esimSentHere)
						self.esimSentHere = {};
					if (!self.esimSentHere[key])
						self.esimSentHere[key] = {};
					self.esimSentHere[key][String(seq)] = true;
				}
			}
			if (pending.action === 'delete-plan') {
				var wanted = (self.esimPlanWanted || {})[modemId];
				delete (self.esimPlanWanted || {})[modemId];
				var planSubject = wanted && wanted.subjectKey
					? self.subjectByKey(wanted.subjectKey) : null;
				if (!wanted || !planSubject || !endpoint)
					return null;
				return self.collectDeletePlan(planSubject, endpoint, action, wanted);
			}
			if (!pending.follow || !mayHaveChanged || !endpoint)
				return null;
			return self.readEndpointCard(modemId, endpoint);
		}).then(function() {
			if (key)
				delete self.esimCardPending[key];
			delete self.esimSettling[modemId];
			/* The modem's own documents move too: a switch changes which
			 * subscription is in use, and an operation that held the modem
			 * changes what its status says. */
			return self.refreshDocuments();
		}).catch(function() {
			if (key)
				delete self.esimCardPending[key];
			delete self.esimSettling[modemId];
			if (!self.userEditing)
				self.renderRoute();
		});
	},

	/* The endpoint does not come straight back.
	 *
	 * Measured on the reference router 2026-09-01: after an operation releases
	 * its inhibit, ModemManager needs seven to thirteen seconds to re-enumerate
	 * the modem it has just been handed, and for that whole window the endpoint
	 * cannot be resolved at all -- a `delete-confirm` inside it blocked with
	 * `endpoint_unavailable` for a card sitting in the slot. So this asks
	 * again, on a budget that covers the window with room, rather than reading
	 * the instant an operation ends and calling the refusal an answer. */
	waitForEndpoint: function(modemId, endpointId, attempts) {
		var self = this;
		attempts = attempts == null ? 6 : attempts;
		var delay = self.esimRetryDelay == null ? 3000 : self.esimRetryDelay;
		return self.reloadEsimInventory(modemId).then(function() {
			var endpoint = endpointId ? self.endpointById(modemId, endpointId) : null;
			if (endpoint || attempts <= 0 || !endpointId)
				return endpoint;
			if (!self.userEditing)
				self.renderRoute();
			return new Promise(function(resolve) { setTimeout(resolve, delay); })
				.then(function() {
					return self.waitForEndpoint(modemId, endpointId, attempts - 1);
				});
		});
	},

	endpointById: function(modemId, endpointId) {
		var inventory = this.esimInventory(modemId);
		var endpoints = inventory && !inventory.error && Array.isArray(inventory.endpoints)
			? inventory.endpoints : [];
		var found = endpoints.filter(function(endpoint) {
			return endpoint.modem_id === modemId && endpoint.endpoint_id === endpointId;
		});
		return found.length === 1 ? found[0] : null;
	},

	esimOperationFor: function(subject) {
		if (subject.kind !== 'modem' || !subject.modem)
			return null;
		var documents = this.documents;
		var modemId = subject.modem.modem_id;
		if ((this.esimPending || {})[modemId])
			return (documents && documents.esimAction && documents.esimAction[modemId]) ||
				{ version: 'v1', busy: true, status: 'starting',
					action: this.esimPending[modemId].action };
		if (!documents || !documents.esimAction)
			return null;
		return documents.esimAction[modemId] || null;
	},

	/* The eSIM coordinator's own terminal words. `succeeded` is this package's
	 * spelling of success, and mapping an unrecognised class to `partial` -- as
	 * the contract requires -- would otherwise turn every successful eSIM
	 * operation into an unfinished one. */
	esimTerminalClass: function(status) {
		switch (status) {
		case 'succeeded':
		case 'failed':
		case 'blocked':
		case 'idle':
		case '':
		case null:
		case undefined:
			return status || 'idle';
		case 'starting':
		case 'running':
			return 'running';
		}
		return 'partial';
	},

	esimActionLabel: function(action) {
		switch (action) {
		case 'read-takeover': return _('eUICC read');
		case 'card-probe': return _('Card identification');
		case 'download': return _('subscription download');
		case 'enable': return _('subscription switch-on');
		case 'disable': return _('subscription switch-off');
		case 'nickname': return _('renaming');
		case 'notification-send': return _('message delivery');
		case 'notification-remove': return _('message discard');
		case 'delete-plan': return _('preparation to remove a subscription');
		case 'delete':
		case 'delete-confirm': return _('subscription removal');
		}
		return action || _('eSIM operation');
	},

	/* The result of the last eSIM operation on this modem, in the three
	 * classes the contract keeps apart -- and `partial` is neither of the other
	 * two, takes the attention colour rather than the failure colour, and is
	 * counted as neither a success nor a failure anywhere. */
	esimOperationNodes: function(subject) {
		var self = this;
		var action = self.esimOperationFor(subject);
		if (!action || action.error)
			return [];
		var label = self.esimActionLabel(action.action);
		if (action.busy === true)
			return [ E('p', { 'class': 'apn-tone-busy' }, [
				_('The %s is running. This page is following it.').format(label)
			]) ];

		var klass = self.esimTerminalClass(action.status);
		if (klass === 'idle')
			return [];
		/* A plan speaks for itself and does not need a banner about itself.
		 * It changed nothing: what it produced is either the confirmation
		 * dialog that opened, or the sentence beside the eUICC saying why
		 * there will not be one. Announcing "the preparation was refused" in
		 * the failure colour above that sentence says the same thing twice,
		 * the second time more alarmingly than the truth -- a removal that is
		 * not permitted yet is not a failure of the router.
		 *
		 * Only while it runs is there something to say, and there it matters:
		 * reading the card took 24 seconds on the FM350-GL, and a page that
		 * looked idle for that long after a press is a page that gets pressed
		 * again. That line is drawn above, before this. */
		if (action.action === 'delete-plan')
			return [];
		if (klass === 'succeeded')
			return [ E('p', { 'class': 'apn-tone-good' }, [
				_('The last %s finished: %s').format(label, action.message || _('it completed'))
			]) ];
		if (klass === 'partial')
			return [ E('div', { 'class': 'apn-partial apn-tone-warn' }, [
				E('p', {}, [ _('Unfinished — part of the change was made.') ]),
				E('p', {}, [ self.esimReasonText(action) ]),
				E('p', {}, [ _('Nothing further is being tried automatically. The next step is yours.') ])
			].concat(self.esimStageNodes(action))
				.concat(self.esimDeliveryNodes(action))) ];
		return [ E('div', { 'class': 'apn-tone-bad' }, [
			E('p', {}, [ klass === 'blocked'
				? _('The last %s was refused.').format(label)
				: _('The last %s failed.').format(label) ]),
			E('p', {}, [ self.esimReasonText(action) ])
		].concat(self.esimStageNodes(action))
			.concat(self.esimDowngradeNodes(subject, action))) ];
	},

	/* What the company that issued the subscription was told, where the result
	 * says anything about it at all. It is a different question from what the
	 * card holds, and a `partial` is usually a disagreement between the two. */
	esimDeliveryNodes: function(action) {
		var value = action && action.notification_delivery;
		if (!value || value === 'none')
			return [];
		return [ E('p', {}, [ this.notificationDeliveryText(value) ]) ];
	},

	/* The one downgrade this project permits, offered only where the backend
	 * says this failure may be retried with it, and only on the verb that can
	 * be repeated. A deletion is verified-only by construction: what its
	 * unknown-issuer failure leaves behind is a message on the card, and that
	 * is what `notification-send` retries. */
	esimDowngradeNodes: function(subject, action) {
		var self = this;
		if (!action || action.reason !== 'tls_untrusted_issuer')
			return [];
		if (action.transport_retry_allowed !== true)
			return [];
		var endpoint = self.endpointById(subject.modem.modem_id, action.endpoint_id);
		if (!endpoint)
			return [];
		if (action.action === 'notification-send' && action.sequence != null)
			return [ E('div', { 'class': 'apn-button-row' }, [
				self.control('esim-notif-send', _('Try again without verifying the provider'),
					'cbi-button-negative', function() {
						self.offerUnverifiedRetry(subject, endpoint, 'notification-send',
							[ String(action.sequence) ]);
					}, { busy: self.subjectBusy(subject) })
			]) ];
		if (action.action === 'download')
			return [ E('div', { 'class': 'apn-button-row' }, [
				self.control('esim-download', _('Try again without verifying the provider'),
					'cbi-button-negative', function() {
						self.offerUnverifiedRetry(subject, endpoint, 'download', []);
					}, { busy: self.subjectBusy(subject) })
			]) ];
		return [];
	},

	esimStageNodes: function(action) {
		var stages = action && action.stages ? String(action.stages) : '';
		if (!stages)
			return [];
		return [ E('p', { 'class': 'apn-area-note' }, [
			_('Stages that completed: %s.').format(stages.replace(/,/g, ', '))
		] ) ];
	},

	/* Every reason the eSIM package publishes that a person has to act on, in
	 * words rather than as a code. The ones that matter most are the states
	 * where the card and the issuer disagree: a subscription that is on the
	 * card while the company that sold it has not been told is not an error to
	 * tuck away, it is unfinished business with an action attached. */
	esimReasonText: function(action) {
		var reason = action && action.reason;
		switch (reason) {
		/* A download that changed the card. */
		case 'download_install_unreported':
			return _('The subscription is on the card and the company that issued it has not been told. The message that tells them is still on the card and can be sent from here.');
		case 'download_install_unconfirmed':
			return _('The subscription is on the card. Whether the company that issued it has been told could not be established, because the card could not be read afterwards.');
		case 'download_install_unacknowledged':
			return _('The subscription is on the card and the company that issued it has been told. Only the software that talks to the card was unhappy afterwards.');
		case 'download_install_uncertain':
			return _('Whether a subscription reached the card at all could not be established. Read the eUICC to find out before trying again.');
		case 'download_refused_no_memory':
			return _('The card refused: it has no room for another subscription. Nothing was written to it.');
		/* A deletion that changed the card. Every one of these is a `partial`
		 * and none of them is a success. */
		case 'delete_unreported':
			return _('The subscription is gone and the company that issued it has not been told. The message that tells them is still on the card and can be sent from here.');
		case 'delete_report_unconfirmed':
			return _('The subscription is gone. Whether a message is still waiting for the company that issued it could not be established, because the card’s list could not be read.');
		case 'delete_notification_deferred':
			return _('The subscription is gone. This way of talking to the card does not publish the message until the modem is handed back, so read the eUICC again to find it.');
		case 'delete_notification_absent':
			return _('The subscription is gone and no message appeared for the company that issued it. It either asked for none or has not written one yet, and those two cannot be told apart from here.');
		case 'delete_unconfirmed':
			return _('The software that talks to the card said the subscription was removed, and the card still lists it. Read the eUICC again before deciding anything.');
		case 'delete_card_unreadable':
			return _('The removal was asked for and the card could not be read afterwards, so what is on it now is not known.');
		case 'delete_interrupted':
			return _('The operation was stopped after the removal had been asked for. Read the eUICC to see what is on it now.');
		case 'delete_refused':
			return _('The card refused the removal and nothing was removed.');
		/* Refusals that need words rather than codes. */
		case 'sole_uplink':
			return _('This modem is the only way out of this router, and this operation needs the network while the modem is unavailable. It was refused rather than started.');
		case 'tls_chain_unparseable':
			return _('This router’s security library cannot read the certificate chain this provider sends, so the connection cannot be verified. There is nothing to retry: going ahead without verification fails in exactly the same way.');
		case 'tls_untrusted_issuer':
			return _('The certificate this provider sends is not signed by an authority this router trusts.');
		case 'endpoint_unreachable':
			return _('The eUICC stopped being reachable before the operation could act on it.');
		case 'modemmanager_unavailable':
			return _('ModemManager does not name this modem, so it could not be taken from it.');
		case 'no_control_port':
			return _('No way of talking to the card could be found after the modem was taken over.');
		case 'endpoint_unproven':
			return _('This eUICC’s own identifier has never been read, so no operation may target it.');
		}
		return (action && action.message) || _('The reason was not given.');
	},

	/* What the company that issued a subscription has been told, which is not
	 * the same question as what the card holds. */
	notificationDeliveryText: function(value) {
		switch (value) {
		case 'delivered':
			return _('The company that issued it has taken the message.');
		case 'delivered_unverified':
			return _('The message was accepted by something that could not be shown to be the right company, so it is still on the card. The usual cause is the network rather than the provider: trying again from a different network is the useful next step.');
		case 'partial':
			return _('Some of the messages were taken and some were not.');
		case 'pending':
			return _('The message is still on the card and has not been taken.');
		case 'none':
			return _('There was no message to send.');
		}
		return _('Whether the message was taken could not be established.');
	},

	/* ---- workspace: APN ---------------------------------------------------- */

	apnAreaNodes: function(subject) {
		var self = this;
		var status = subject.status;
		var nodes = [ E('h4', {}, [ _('APN') ]) ];

		if (!status || status.error) {
			nodes.push(unknownLine(_('The APN profile of this connection'),
				status && status.error ? status.error : _('This connection could not be read just now.')));
			return nodes;
		}

		nodes = nodes.concat(self.incompleteNotice(status));

		var state = resultState(status);
		var rows = [
			row(_('Active profile'), status.configured_apn || _('<empty>')),
			row(_('Matched provider'), simProviderLabel(status),
				_('The database record this APN profile was selected from. While roaming it differs from the network currently carrying the link, which is shown under Connection.')),
			row(_('Cached APN for this SIM'), status.cached_apn,
				_('The profile last verified for this SIM. It is reused instead of searching the database again.')),
			row(_('Reconciled APN'), status.reconciled_apn)
		];
		/* The verdict slot, and the verdict slot is a line: the code belongs
		 * where the result is a reason to do something — beside the connection
		 * control when a wanted connection did not hold, and under the demoted
		 * result below, which a user has to weigh. Repeating it here as well
		 * would be the same fact at full fidelity in two areas. */
		if (state === 'current')
			rows.push(row(_('Last check'), status.last_result || _('Nothing recorded yet')));
		else
			rows.push(row(_('Last check'), state === 'previous'
				? _('— no check has finished for the SIM that is here now')
				: _('— not checked yet for this SIM')));
		nodes.push(table(rows));

		/* The demoted result keeps its text, its code and its reason, and it
		 * lives here rather than in Diagnostics: a user can act on it, and
		 * hiding it behind a maintainer disclosure is losing it. */
		if (state !== 'current' && status.last_result)
			nodes.push(self.demotedResultNode(status, state));

		var buttons = [];
		var apply = targetGate(status, 'profile_apply');
		if (apply === 'yes' && subject.targetId) {
			buttons.push(self.reconcileOneControl(subject));
			buttons.push(self.manualApnControl(subject));
		}
		else if (apply === 'no')
			nodes.push(refusalLine(_('This connection’s backend cannot write APN profiles, so the APN cannot be re-checked or set by hand from here.')));
		else
			nodes.push(unknownLine(_('Whether this connection’s APN can be written'),
				_('The installed version of this program does not report it. Updating the packages would answer it.')));
		if (buttons.length)
			nodes.push(E('div', { 'class': 'apn-button-row' }, buttons));

		nodes = nodes.concat(self.roamingNodes(subject));

		nodes.push(advanced([
			row(_('Engine target'), status.target_id),
			row(_('Protocol / backend'), '%s / %s'.format(status.target_protocol, status.target_backend)),
			row(_('Chosen from'), status.database_version
				? _('provider database %s').format(status.database_version) : status.database_path),
			row(_('Manual operator lock (PLMN)'), status.configured_plmn),
			row(_('Database format'), status.database_format ? 'v%s'.format(status.database_format) : ''),
			row(_('Sources'), status.database_sources),
			row(_('Source revisions'), status.database_revisions),
			row(_('Database path'), status.database_path)
		]));

		return nodes;
	},

	demotedResultNode: function(status, state) {
		var reason = resultStaleReasonText(status.result_stale_reason);
		var parts = [ status.last_result ];
		if (status.result_code)
			parts.push(_('code %s').format(status.result_code));
		var explanation = state === 'previous'
			? _('Recorded for a different SIM or a different attachment.')
			: _('Recorded earlier, and nothing here can confirm it is about the modem and SIM present now.');
		return E('div', { 'class': 'apn-demoted apn-demoted-' + state }, [
			E('h5', {}, [ state === 'previous' ? _('Previous result') : _('Result, unconfirmed') ]),
			E('div', { 'class': 'apn-demoted-text' }, [ parts.join(' · ') ]),
			E('div', { 'class': 'apn-demoted-note' }, [
				reason ? '%s %s'.format(explanation, _('Reason: %s.').format(reason)) : explanation
			])
		]);
	},

	/* Roaming permission is a one-target decision and there is no scope in v2
	 * that could fan it out. Apply is rendered only once the selection differs
	 * from what is recorded: a control that cannot do anything is not drawn,
	 * and a greyed one would claim an operation is running. */
	roamingNodes: function(subject) {
		var self = this;
		var status = subject.status;
		var nodes = [ E('h5', {}, [ _('Roaming data policy') ]) ];
		var permitted = roamingPolicyGate(status);

		if (permitted === 'no') {
			nodes.push(refusalLine(roamingPolicyRefusal(status)));
			return nodes;
		}
		if (permitted === 'unknown') {
			nodes.push(unknownLine(_('Whether the roaming data policy can be changed here'),
				_('The installed version of this program does not report it. Updating the packages would answer it.')));
			return nodes;
		}

		nodes.push(E('p', {}, [ roamingPolicyDescription(status) ]));
		nodes.push(row(_('Current'), roamingPolicyLabel(status)));

		var recorded = policyValue(status);
		var applyRow = E('div', { 'class': 'apn-button-row' }, []);
		var options = [];
		if (roamingPolicyCustom(status))
			options.push(E('option', { 'value': 'custom' }, [ _('Custom configuration (unchanged)') ]));
		options.push(E('option', { 'value': 'default' }, [ defaultPolicyOptionLabel(status) ]));
		options.push(E('option', { 'value': 'allow' }, [ _('Explicitly allow') ]));
		options.push(E('option', { 'value': 'block' }, [ _('Explicitly block') ]));

		var select = E('select', {
			'class': 'cbi-input-select',
			'data-apn-control': 'roaming-policy',
			'change': function() {
				/* A poll must never replace a form the user has touched, so
				 * the page records that this one has been. */
				self.userEditing = select.value !== recorded;
				dom.content(applyRow, select.value === recorded || select.value === 'custom'
					? [] : [ self.roamingApplyControl(subject, select) ]);
			}
		}, options);
		select.value = recorded;
		if (self.subjectBusy(subject))
			select.disabled = true;
		self.controls.push(select);
		self.policySelect = select;

		nodes.push(E('div', { 'class': 'apn-policy-controls' }, [ select ]));
		nodes.push(applyRow);
		nodes.push(E('p', { 'class': 'apn-area-note' }, [
			_('Allowing roaming data does not mean roaming is included in your tariff or free of charge.')
		]));
		return nodes;
	},

	roamingApplyControl: function(subject, select) {
		var self = this;
		return self.control('roaming-policy', _('Apply'), 'cbi-button-action', function() {
			self.confirmRoamingPolicy(subject, select.value);
		}, { busy: self.subjectBusy(subject) });
	},

	/* ---- workspace: Modem --------------------------------------------------- */

	modemAreaNodes: function(subject) {
		var self = this;
		var nodes = [ E('h4', {}, [ _('Modem') ]) ];

		if (subject.kind === 'target') {
			nodes.push(E('p', {}, [
				_('The modem this connection was set up for is not attached. Its settings are kept and nothing is being retried.')
			]));
			nodes.push(unknownLine(_('This connection’s hardware'),
				_('Removing the setup needs the modem present, because the operation is addressed to the modem rather than to the connection.')));
			nodes.push(table([
				row(_('Interface'), subject.section),
				row(_('Protocol'), subject.target && subject.target.protocol),
				row(_('Looked after automatically'), subject.target && subject.target.managed === true
					? _('yes') : _('no'))
			]));
			return nodes;
		}

		var modem = subject.modem;
		var plan = subject.plan || {};
		var rows = [
			row(_('Model'), self.modemModelLabel(modem)),
			row(_('Protocol'), modem.protocol),
			row(_('Control owner'), self.modemOwnerStateLabel(modem.owner_state),
				_('Which component is allowed to talk to this modem. Two components claiming it at once stops every operation rather than racing them.')),
			row(_('Network interface'), subject.section || _('none')),
			row(_('Looked after automatically'), self.managedLabel(subject),
				_('Whether automatic operations act on this connection. It is the engine’s own answer: a section this program staged but has not finished is deliberately not looked after.'))
		];
		if (subject.ambiguous)
			rows.push(row(_('Identification'), modem.ambiguity_reason || _('could not be told apart from another modem')));
		nodes.push(table(rows));

		if (subject.ambiguous) {
			nodes.push(E('p', { 'class': 'apn-area-note' }, [
				_('This is an unfinished observation rather than a failure. Removing one of the two devices, or a firmware that reports a serial number, would resolve it. No action is offered here.')
			]));
			nodes.push(self.modemAdvanced(modem));
			return nodes;
		}

		if (plan.error)
			nodes.push(unknownLine(_('Whether this modem can be set up'),
				_('Its record carries no provisioning verdict, which is what a check that could not run and a version of this program that does not report one both look like from here. Reading again, or updating the packages, would answer it.')));
		else if (gate(plan.can_provision) === 'yes') {
			nodes.push(E('p', {}, [
				_('This modem is not set up yet. Setting it up creates a new network interface called %s, finds the right APN for its SIM, verifies real Internet access and only then enables automatic connection. If anything fails, everything is undone.')
					.format(text(plan.section))
			]));
			nodes.push(E('div', { 'class': 'apn-button-row' }, [
				self.bearerControl(subject, 'provision', _('Set up connection'), 'cbi-button-action important')
			]));
		}
		else if (gate(plan.can_provision) === 'no') {
			nodes.push(refusalLine(self.provisionReasonText(plan.reason, modem)));
			/* The gate is the origin and nothing else. A section this program
			 * created may be removed; an adopted one is owned and is released
			 * rather than deleted, and it must never reach this verb. An
			 * absent origin is unknown, so no control at all: the alternative
			 * is inferring "created" from ownership, which is exactly the
			 * inference that would delete somebody's own interface. */
			if (plan.reason === 'already_provisioned' && plan.existing_section) {
				if (plan.connection_origin === 'created')
					nodes.push(E('div', { 'class': 'apn-button-row' }, [
						self.bearerControl(subject, 'deprovision', _('Remove setup'), 'cbi-button-remove')
					]));
				else if (plan.connection_origin == null)
					nodes.push(unknownLine(_('Whether this setup may be removed from here'),
						_('The installed version of this program does not report who created this interface. Updating the packages would answer it.')));
			}
		}
		else
			nodes.push(unknownLine(_('Whether this modem can be set up'),
				_('The installed version of this program does not report it. Updating the packages would answer it.')));

		nodes = nodes.concat(self.resetNodes(subject));
		nodes.push(self.modemAdvanced(modem));
		return nodes;
	},

	managedLabel: function(subject) {
		if (!subject.target)
			return _('no connection yet');
		return subject.target.managed === true ? _('yes') : _('no');
	},

	/* Reset stopped being a board-integration feature: the backend picks a
	 * method from whoever owns the modem, so the control is offered whenever
	 * it says one applies — and only when this modem has an interface of its
	 * own to name. */
	resetNodes: function(subject) {
		var self = this;
		var modem = subject.modem;
		var nodes = [ E('h5', {}, [ _('Restarting this modem') ]) ];
		var reset = modem.capabilities ? gate(modem.capabilities.reset) : 'unknown';

		if (reset === 'unknown') {
			nodes.push(unknownLine(_('Whether this modem can be restarted from here'),
				_('The installed version of this program does not report it. Updating the packages would answer it.')));
			return nodes;
		}
		if (reset === 'no') {
			nodes.push(refusalLine(_('No restart method applies to this modem in its current composition, so it is not offered.')));
			return nodes;
		}
		if (!subject.targetId) {
			nodes.push(refusalLine(_('This modem has no network interface of its own yet, and a restart is addressed to one. Set up the connection first.')));
			return nodes;
		}

		nodes.push(table([
			row(_('Method'), self.modemResetMethodLabel(modem.reset_method),
				_('How this modem would be restarted. Board power is used wherever the hardware supports it; otherwise the component that owns the modem is asked to reset it, or a reset command is sent over the modem’s own control port.'))
		]));
		nodes.push(E('div', { 'class': 'apn-button-row' }, [ self.resetControl(subject) ]));
		return nodes;
	},

	modemAdvanced: function(modem) {
		var self = this;
		return advanced([
			row(_('Modem identity'), sensitiveIdentifier(modem.modem_id, _('modem identity'))),
			row(_('Evidence'), modem.evidence_tier),
			row(_('Firmware'), modem.firmware_revision),
			row(_('Reset method'), self.modemResetMethodLabel(modem.reset_method)),
			row(_('Implementation'), modem.implementation_state),
			row(_('Validation'), modem.hardware_validated ? _('hardware') : modem.validation_state),
			row(_('USB path'), modem.usb_path),
			row(_('AT control port'), modem.at_device),
			row(_('Vendor / product'), modem.vendor_id && modem.product_id
				? '%s:%s'.format(modem.vendor_id, modem.product_id) : ''),
			row(_('Control device'), modem.control_device),
			row(_('Data device'), modem.data_device),
			row(_('First seen'), formatTimestamp(modem.first_seen))
		]);
	},

	modemOwnerStateLabel: function(state) {
		switch (state) {
		case 'none': return _('No active control session');
		case 'netifd-direct': return _('Controlled directly by netifd');
		case 'modemmanager': return _('Controlled by ModemManager');
		case 'transitioning': return _('Reset in progress');
		case 'conflicting': return _('Conflicting owners — no operation will start');
		default: return text(state);
		}
	},

	modemResetMethodLabel: function(method) {
		switch (method) {
		case 'gpio': return _('Board power cycle');
		case 'modemmanager': return _('Through ModemManager');
		case 'at': return _('Command over the control port');
		case 'none': return _('Not available');
		}
		return text(method);
	},

	/* ---- workspace: Diagnostics --------------------------------------------- */

	/* Where a maintainer's fact goes, and never where a fact the user can act
	 * on goes. A demoted result, an abandoned read that changes what the page
	 * can say, and a refusal with a next step all stay beside the thing they
	 * are about. */
	diagnosticsAreaNodes: function(subject) {
		var self = this;
		var status = subject.status;
		var nodes = [ E('h4', {}, [ _('Diagnostics') ]) ];

		var reads = incompleteReads(status);
		nodes.push(E('h5', {}, [ _('Readings that were abandoned') ]));
		nodes.push(E('p', {}, [ reads.length
			? _('The last read gave up on: %s. The engine answers with what it did obtain rather than with nothing.').format(reads.join(', '))
			: _('None. The last read of this connection completed.') ]));

		nodes.push(E('h5', {}, [ _('Subsystems') ]));
		var inventory = self.documents && self.documents.inventory;
		nodes.push(table([
			row(_('Modem coordinator'), inventory && inventory.error
				? _('unreachable: %s').format(inventory.error) : _('answering')),
			row(_('eSIM package'), _('not installed')),
			row(_('Engine status for this connection'), status && status.error
				? _('unreachable: %s').format(status.error) : _('answering'))
		]));

		nodes.push(E('h5', {}, [ _('Last operation') ]));
		nodes.push(E('p', {}, [ self.operationDetailText(subject) ]));

		if (status && !status.error)
			nodes.push(advanced([
				row(_('Implementation / validation'), '%s / %s'.format(
					status.target_implementation_state || '—', status.target_validation_state || '—')),
				row(_('Hardware validated'), status.target_hardware_validated ? _('yes') : _('no')),
				row(_('Effective data device'), status.l3_device || status.device),
				row(_('Board integration'), status.hardware_integration || _('none'))
			]));

		return nodes;
	},

	/* ---- operations ---------------------------------------------------------- */

	actionLabel: function(action) {
		switch (action) {
		case 'reconcile': return _('APN re-check');
		/* Nobody pressed anything: the modem came back and the program is
		 * catching up with it. Naming it is the difference between a page that
		 * looks stuck and a page that is explaining itself. */
		case 'converge': return _('automatic catch-up after the modem reconnected');
		case 'modem-reset': return _('modem restart');
		case 'apply-manual': return _('manual APN');
		case 'provision': return _('connection setup');
		case 'deprovision': return _('setup removal');
		case 'connect': return _('connect');
		case 'disconnect': return _('disconnect');
		case 'reconnect': return _('reconnect');
		case 'roaming-default':
		case 'roaming-allow':
		case 'roaming-block': return _('roaming policy change');
		case 'database-check': return _('database update check');
		case 'database-install': return _('database installation');
		default: return action || _('operation');
		}
	},

	operationLabel: function(operation) {
		return _('%s — running').format(this.actionLabel(operation && operation.action));
	},

	/* The stages the convergence worker publishes while it runs. They are the
	 * only part of an operation a user can see the reason for, so they are
	 * shown as themselves rather than folded into "working on this modem". */
	convergeStageText: function(message) {
		switch (message) {
		case 'waiting for SIM':
			return _('Waiting for the SIM to become readable.');
		case 'reconciling after modem reconnect':
			return _('Re-checking the APN now that the modem is back.');
		}
		return '';
	},

	operationStageText: function(operation) {
		if (!operation || operation.error)
			return '';
		if (operation.action === 'converge') {
			var stage = this.convergeStageText(operation.message);
			return stage ? '%s %s'.format(_('This modem reconnected and is being caught up.'), stage)
				: _('This modem reconnected and is being caught up.');
		}
		if (operation.stage_index && operation.stage_count)
			return _('Stage %s of %s (%s)').format(operation.stage_index, operation.stage_count,
				operation.message || '');
		return operation.message || '';
	},

	/* One line for the workspace header, whichever component is busy. The
	 * engine owns the operations a user starts; the coordinator owns the one
	 * that starts itself, and before it reaches the engine's reconcile there
	 * is nothing in the engine's own state to show. */
	runningDescription: function(subject) {
		var action = this.documents && this.documents.action;
		if (action && !action.error && action.busy)
			return this.actionDescription(action);
		var operation = subject && subject.operation;
		if (operation && !operation.error && operation.busy)
			return '%s %s'.format(this.operationLabel(operation), this.operationStageText(operation)).trim();
		return '';
	},

	actionDescription: function(action) {
		if (!action || action.error)
			return action && action.error || _('Operation status is unavailable');
		var label = this.actionLabel(action.action);
		switch (action.state) {
		case 'starting':
		case 'queued': return _('The %s is queued.').format(label);
		case 'running': return _('The %s is running. Please wait; this may take over a minute.').format(label);
		case 'external': return _('An APN, modem or database operation started outside this page is running.');
		}
		return _('The %s is running.').format(label);
	},

	/* A terminal class the page does not recognise is rendered as `partial`:
	 * unfinished, not failed and not done. An unknown terminal state after an
	 * operation that may have changed the modem is exactly the state that
	 * needs a person, and calling it a success is the one answer that is
	 * certainly wrong. */
	terminalClass: function(state) {
		switch (state) {
		case 'success':
		case 'failed':
		case 'blocked':
		case 'retryable':
		case 'idle':
		case '':
		case null:
		case undefined:
			return state || 'idle';
		}
		return 'partial';
	},

	operationDetailText: function(subject) {
		var operation = subject.operation;
		if (!operation || operation.error)
			return operation && operation.error
				? _('The operation state could not be read: %s').format(operation.error)
				: _('No operation has run for this modem since the program started.');
		if (operation.busy)
			return '%s %s'.format(this.operationLabel(operation), this.operationStageText(operation)).trim();
		var label = this.actionLabel(operation.action);
		switch (this.terminalClass(operation.state)) {
		case 'success': return _('The last %s finished successfully.').format(label);
		case 'failed': return _('The last %s failed: %s').format(label, operation.message || _('unknown error'));
		case 'blocked': return _('The last %s was refused: %s').format(label, operation.message || _('not permitted'));
		case 'retryable': return _('The last %s could not finish and may be retried: %s').format(label, operation.message || '');
		case 'partial': return _('Unfinished — part of the change was made. The last %s did not complete and cannot be undone automatically. The next step is yours; nothing further is being tried.').format(label);
		}
		return _('No operation is running.');
	},

	/* ---- abandoned reads ------------------------------------------------------ */

	/* The engine returns what it did obtain and names what it gave up on, so
	 * the page says exactly that. It is deliberately a notice rather than a
	 * warning: nothing failed and no hardware is missing — a reading was cut
	 * short so that the command could answer at all, and the action that fixes
	 * it is to read again. */
	incompleteNotice: function(status) {
		var self = this;
		var reads = incompleteReads(status);
		if (!reads.length && !(status && status.incomplete === true))
			return [];

		var message = reads.length
			? _('Some readings could not be completed in time and are missing below: %s. Nothing here says that hardware is absent — it says it was not read.')
				.format(reads.join(', '))
			: _('Some readings could not be completed in time and are missing below. Nothing here says that hardware is absent — it says it was not read.');

		var retry = E('button', {
			'class': 'btn cbi-button cbi-button-neutral',
			'type': 'button',
			'data-apn-nav': 'read-again',
			'click': function(ev) {
				ev.preventDefault();
				if (retry.disabled)
					return;
				retry.disabled = true;
				self.refreshDocuments().catch(function() {}).then(function() { retry.disabled = false; });
			}
		}, [ _('Read again') ]);

		return [ E('div', { 'class': 'alert-message notice apn-incomplete' }, [
			E('p', {}, [ message ]),
			E('div', { 'class': 'apn-button-row' }, [ retry ])
		]) ];
	},

	/* ---- Provider database ------------------------------------------------------ */

	databaseNodes: function() {
		var self = this;
		var database = self.documents && self.documents.database;
		var nodes = [ E('h3', {}, [ _('Provider database') ]),
			E('p', {}, [ _('The signed provider package can be checked and updated independently from the program and this page. Updating it does not change the active APN.') ]) ];

		if (!database || database.error) {
			nodes.push(unknownLine(_('The state of the provider database'),
				database && database.error ? database.error : _('The database helper did not answer.')));
			return nodes;
		}

		var warning = database.state === 'check-failed' || database.state === 'install-failed' ||
			!database.feed_configured || !database.key_trusted;
		nodes.push(E('div', { 'class': warning ? 'alert-message warning' : 'alert-message notice' },
			[ text(database.message) ]));

		var rows = [
			row(_('Installed package version'), database.installed_package_version),
			row(_('Database version'), database.database_version),
			row(_('Data release date'), databaseReleaseDate(database.database_version)),
			row(_('Last update check'), formatTimestamp(database.checked_at) || _('Not checked yet')),
			row(_('Last installation through this page'), formatTimestamp(database.installed_at) || _('Not recorded'))
		];
		if (database.update_available)
			rows.splice(3, 0, row(_('Available package version'), database.available_package_version));
		nodes.push(table(rows));

		var buttons = [ self.control('db-check', _('Check for provider data'), 'cbi-button-action', function() {
			self.startAction('database-check', null);
		}, { busy: self.engineBusy }) ];
		/* Rendered only when there is an update to install: the gate is the
		 * database's own answer, and a control that cannot do anything is not
		 * drawn at all. */
		if (database.update_available)
			buttons.push(self.control('db-install', _('Install provider data'), 'cbi-button-positive', function() {
				self.confirmDatabaseInstall();
			}, { busy: self.engineBusy }));
		nodes.push(E('div', { 'class': 'apn-button-row' }, buttons));

		nodes.push(advanced([
			row(_('Signed package feed'), trustLabel(database.feed_configured, _('Configured'), _('Not configured'))),
			row(_('Repository signing key'), trustLabel(database.key_trusted, _('Trusted'), _('Not installed'))),
			row(_('Feed URL'), database.feed_url)
		]));
		return nodes;
	},

	/* ---- confirmations and launches ---------------------------------------------- */

	/* Every state-changing verb is confirmed first, and the confirmation names
	 * the scope it is about to act on in the words the user reads elsewhere on
	 * the page. Reaching a control through one modem's workspace is not what
	 * makes it act on that modem: the control passes the identity, and the
	 * confirmation states it. */
	confirmModemAction: function(subject, verb) {
		var self = this;
		if (self.subjectBusy(subject))
			return;

		var plan = subject.plan || {};
		var section = subject.section || plan.connection_section || plan.existing_section || '';
		var adoptSection = plan.adoption_section || section;
		var titles = {
			provision: _('Set up this modem'),
			deprovision: _('Remove setup'),
			adopt: _('Let AutoAPN manage settings'),
			'release-adoption': _('Stop managing settings'),
			connect: _('Connect'),
			disconnect: _('Disconnect'),
			reconnect: _('Reconnect')
		};
		var bodies = {
			provision: _('A new network interface called %s will be created for this modem. Its APN is chosen and verified before automatic connection is enabled. Nothing else on this router is changed.').format(plan.section || ''),
			deprovision: _('The network interface %s created for this modem will be stopped and removed. Interfaces you created yourself are never touched.').format(plan.existing_section || ''),
			connect: _('This asks netifd to bring the interface %s up. No configuration is changed.').format(section),
			disconnect: _('This stops the interface %s. Any connection through it will be interrupted. No configuration is changed.').format(section),
			reconnect: _('This stops and restarts the interface %s. Connectivity will be interrupted briefly. No configuration is changed.').format(section),
			/* Both name the modem and the section, because the operation is
			 * addressed to the modem and lands on the section, and a user with
			 * two modems must be able to see which pair is meant. */
			adopt: _('This program will look after the APN settings of %s, the interface you created for %s.')
				.format(adoptSection, self.modemModelLabel(subject.modem || {})),
			'release-adoption': _('This program will stop looking after the APN settings of %s, the interface you created for %s.')
				.format(section, self.modemModelLabel(subject.modem || {}))
		};
		var extra = [];
		if (verb === 'provision' && plan.netifd_restart_required === true)
			extra.push(E('p', {}, [ _('The network service is restarted as part of this, so every interface on this router is interrupted briefly.') ]));
		if (verb === 'disconnect')
			extra.push(E('p', {}, [ _('This also records that you want it left down, so the program will not bring it back on its own.') ]));
		if (verb === 'adopt') {
			/* Exactly what it does and exactly what it does not do. Nothing is
			 * recreated, nothing is unplugged and no second interface appears:
			 * the section stays where it is, under its own name, and the
			 * settings it has now are written down first so they can be put
			 * back. */
			extra.push(E('p', {}, [
				_('%s is kept exactly as it is. Its current settings are saved first, so they can be put back later.')
					.format(adoptSection)
			]));
			extra.push(E('p', {}, [
				_('Nothing is disconnected or reconfigured now. The APN is only looked at the next time this program checks the connection.')
			]));
		}
		if (verb === 'release-adoption')
			extra.push(E('p', {}, [
				_('The settings %s had before are put back, and the interface itself is left in place. Nothing is deleted.')
					.format(section)
			]));
		var destructive = verb === 'deprovision' || verb === 'disconnect';

		if (verb === 'adopt' || verb === 'release-adoption')
			extra.push(E('p', { 'class': 'apn-confirm-scope' }, [
				_('This runs against %s only.').format(verb === 'adopt' ? adoptSection : section)
			]));

		self.showConfirmation(titles[verb], bodies[verb], extra, destructive, function() {
			self.startModemAction(subject, verb);
		});
	},

	confirmEngineAction: function(action, target, title, body, scope) {
		var self = this;
		self.showConfirmation(title, body,
			scope ? [ E('p', { 'class': 'apn-confirm-scope' }, [ scope ]) ] : [],
			action === 'modem-reset', function() {
				self.startAction(action, target);
			});
	},

	confirmRoamingPolicy: function(subject, value) {
		var self = this;
		if (value !== 'default' && value !== 'allow' && value !== 'block')
			return;
		var labels = {
			'default': _('Use the OpenWrt default'),
			allow: _('Explicitly allow roaming data'),
			block: _('Explicitly block roaming data')
		};
		self.showConfirmation(_('Change roaming data policy'),
			_('Apply “%s” to %s? If needed, the mobile connection will be stopped or re-established.')
				.format(labels[value], subject.section),
			[ E('p', {}, [ _('Allowing roaming data does not mean that roaming is included in your tariff or free of charge.') ]),
				E('p', { 'class': 'apn-confirm-scope' }, [ _('This runs against %s only.').format(subject.section) ]) ],
			false, function() {
				self.startAction('roaming-' + value, subject.targetId);
			});
	},

	confirmDatabaseInstall: function() {
		var self = this;
		var database = self.documents && self.documents.database;
		if (!database || !database.update_available)
			return;
		self.showConfirmation(_('Install provider data'),
			_('Install signed provider database package %s?').format(database.available_package_version),
			[ E('p', {}, [ _('Only the provider database package will be updated. The active APN and mobile connection will not be changed.') ]),
				E('p', { 'class': 'apn-confirm-scope' }, [ _('This runs against this router only.') ]) ],
			false, function() { self.startAction('database-install', null); });
	},

	/* ---- keeping the keyboard inside a dialog ---- */

	/* Every node in a dialog that a keyboard can land on. */
	dialogFocusables: function(container) {
		var found = [];
		walkNodes(container, function(node) {
			if (node.disabled === true)
				return;
			if (node.tag === 'button' || node.tag === 'select' || node.tag === 'input' ||
				node.tagName === 'BUTTON' || node.tagName === 'SELECT' || node.tagName === 'INPUT')
				found.push(node);
		});
		return found;
	},

	/* Where Tab should go, or null when the browser's own answer is already
	 * right. LuCI's modal does not confine the keyboard — three Tabs out of a
	 * confirmation land on the router's own navigation behind it, with the
	 * dialog still open — and the contract puts that requirement on this page,
	 * so this page answers it. */
	focusCycleTarget: function(container, active, shift) {
		var nodes = this.dialogFocusables(container);
		if (!nodes.length)
			return null;
		var index = nodes.indexOf(active);
		if (index === -1)
			return nodes[0];
		if (!shift && index === nodes.length - 1)
			return nodes[0];
		if (shift && index === 0)
			return nodes[nodes.length - 1];
		return null;
	},

	/* A destructive confirm is never the initially focused control, so the
	 * keyboard starts on the first thing in the dialog that is not the
	 * confirmation — Cancel on a confirmation, the first field on a form. */
	initialDialogFocus: function(container) {
		var nodes = this.dialogFocusables(container);
		for (var index = 0; index < nodes.length; index++) {
			var role = typeof nodes[index].getAttribute === 'function'
				? nodes[index].getAttribute('data-apn-nav') : null;
			if (role !== 'confirm')
				return nodes[index];
		}
		return null;
	},

	/* Open a dialog: remember what the keyboard was on, put it on something
	 * safe inside, and confine Tab to the dialog until it closes. */
	openDialog: function(title, container) {
		var self = this;
		var host = browserWindow();
		self.dialogOpener = host && host.document ? host.document.activeElement : null;
		self.dialogContainer = container;

		if (host && typeof host.addEventListener === 'function' && !self.dialogKeyHandler) {
			self.dialogKeyHandler = function(event) {
				if (!self.dialogContainer)
					return;
				if (event.key === 'Escape') {
					/* LuCI's own handler closes it; this only puts the
					 * keyboard back where it came from. */
					self.closeDialog();
					return;
				}
				if (event.key !== 'Tab')
					return;
				var active = host.document ? host.document.activeElement : null;
				var target = self.focusCycleTarget(self.dialogContainer, active, event.shiftKey === true);
				if (target && typeof target.focus === 'function') {
					if (typeof event.preventDefault === 'function')
						event.preventDefault();
					target.focus();
				}
			};
			host.addEventListener('keydown', self.dialogKeyHandler, true);
		}

		ui.showModal(title, [ container ]);

		/* After the dialog is in the document, never before: focus on a node
		 * that is not attached yet does nothing, and LuCI then parks the
		 * keyboard on the modal wrapper instead. */
		var initial = self.initialDialogFocus(container);
		if (initial && typeof initial.focus === 'function')
			initial.focus();
	},

	/* Close it, and return the keyboard to the control that opened it. */
	stopPlanCountdown: function() {
		if (this.planCountdown && this.planCountdownHost
			&& typeof this.planCountdownHost.clearInterval === 'function')
			this.planCountdownHost.clearInterval(this.planCountdown);
		this.planCountdown = null;
		this.planCountdownHost = null;
	},

	closeDialog: function() {
		var opener = this.dialogOpener;
		this.dialogContainer = null;
		this.dialogOpener = null;
		/* A countdown outliving the dialog it belongs to would write into a
		 * detached node for ever, and on a page that opens this dialog twice
		 * there would be two of them. */
		this.stopPlanCountdown();
		if (opener && typeof opener.focus === 'function')
			opener.focus();
	},

	/* Escape cancels and never confirms; a destructive confirm is never the
	 * initially focused control, which is why Cancel is rendered first and why
	 * the initial focus deliberately skips the confirmation. */
	showConfirmation: function(title, body, extra, destructive, onConfirm, onCancel) {
		var self = this;
		var cancel = E('button', {
			'class': 'btn',
			'type': 'button',
			'data-apn-nav': 'cancel',
			'click': function() {
				ui.hideModal();
				self.closeDialog();
				if (onCancel)
					onCancel();
			}
		}, [ _('Cancel') ]);
		var confirm = E('button', {
			'class': 'btn important ' + (destructive ? 'cbi-button-remove' : 'cbi-button-action'),
			'type': 'button',
			'data-apn-nav': 'confirm',
			'click': function() {
				ui.hideModal();
				self.closeDialog();
				onConfirm();
			}
		}, [ title ]);
		self.openDialog(title, E('div', { 'class': 'apn-confirm-dialog' },
			[ E('p', {}, [ body ]) ].concat(extra || []).concat([
				E('div', { 'class': 'right' }, [ cancel, ' ', confirm ])
			])));
	},

	/* ---- changing which slot is live ----
	 *
	 * A modem operation, and it lives beside the slot table for that reason: a
	 * slot does not become an eSIM matter because a chip happens to sit in
	 * one, and a two-slot modem may hold two ordinary SIMs. What is in the
	 * inactive slot is not powered and cannot be asked; all this changes is
	 * which one the modem is using.
	 *
	 * The dialog is built from `slot-switch-plan` and from nothing else. Every
	 * number in it -- what the change is bounded at, what the wait for a SIM
	 * is bounded at, what the whole thing is bounded at -- is the backend's,
	 * because a page that invents a duration is a page telling somebody how
	 * long to wait for something it has not measured. The plan is fetched when
	 * the control is pressed, never on entry: it is a read on the way to a
	 * mutation and does not go through the scan cache. */
	slotProbeControl: function(subject) {
		var self = this;
		return self.control('modem-slot-probe', _('Ask the modem about its slots'),
			'cbi-button-action', function() { self.askAboutSlots(subject); },
			{ busy: self.subjectBusy(subject) });
	},

	/* One bounded question, and the answer arrives in the next ordinary read
	 * rather than in the reply: what it changes is the table those reads are
	 * served from. So the inventory for this modem is dropped and fetched
	 * again, and nothing else on the page is disturbed. */
	askAboutSlots: function(subject) {
		var self = this;
		if (self.subjectBusy(subject))
			return;
		var modemId = subject.modem.modem_id;
		if (!self.slotProbePending)
			self.slotProbePending = {};
		if (self.slotProbePending[modemId])
			return;
		self.slotProbePending[modemId] = true;
		if (!self.userEditing)
			self.renderRoute();
		return call(modemControlCommand, [ 'sim-slots-probe', modemId ]).then(function() {
			delete self.slotProbePending[modemId];
			if (self.documents && self.documents.esimRead)
				delete self.documents.esimRead[modemId];
			return self.refreshDocuments();
		}).catch(function(error) {
			delete self.slotProbePending[modemId];
			ui.addNotification(null, E('p', {}, [ error.message ]), 'error');
			if (!self.userEditing)
				self.renderRoute();
		});
	},

	slotSwitchControl: function(subject, slot) {
		var self = this;
		return self.control('modem-slot-switch',
			_('Use slot %s').format(String(slot)), 'cbi-button-action', function() {
				self.planSlotSwitch(subject, slot);
			}, { busy: self.subjectBusy(subject) });
	},

	planSlotSwitch: function(subject, slot) {
		var self = this;
		if (self.subjectBusy(subject))
			return;
		return callPlan(modemQueryCommand,
			[ 'slot-switch-plan', subject.modem.modem_id, String(slot) ]).then(function(plan) {
			if (plan.available !== true) {
				ui.addNotification(null, E('p', {},
					[ self.slotSwitchRefusalText(plan) ]), 'warning');
				return;
			}
			self.showSlotSwitchDialog(subject, slot, plan);
		}).catch(function(error) {
			ui.addNotification(null, E('p', {}, [
				_('The slot change could not be described, so nothing was done: %s')
					.format(error.message)
			]), 'error');
		});
	},

	/* The backend's own tokens, in the user's words. */
	slotSwitchRefusalText: function(plan) {
		switch (plan.unavailable_reason) {
		case 'slot-absent':
			return _('This modem does not report a slot with that number.');
		case 'slot-already-active':
			return _('That slot is already the one in use.');
		case 'mechanism-unavailable':
			return _('Nothing on this router can change this modem’s slot: the component that owns it does not offer the operation.');
		case 'no-slot-table':
			return _('This modem publishes no slot table, so no slot change can be proven and none is offered.');
		case 'modem-absent':
			return _('This modem is not attached just now.');
		case 'modem-ambiguous':
			return _('Two modems here cannot be told apart, so neither has its slot changed.');
		case 'owner-unsettled':
			return _('This modem has no settled control owner, so nobody can be asked to change its slot.');
		}
		return _('The slot change was refused, and the reason was not one this page knows.');
	},

	showSlotSwitchDialog: function(subject, slot, plan) {
		var self = this;
		var iface = plan.interrupts_interface || '';
		var body = _('The modem starts using the SIM in slot %s instead of the one in slot %s. Whatever is in the slot it leaves is not removed; it simply stops being the one in use.')
			.format(String(slot), String(plan.active_slot));
		var extra = [];
		if (iface)
			extra.push(E('p', {}, [
				_('The connection on %s stops while it happens.').format(iface)
			]));
		if (durationLabel(plan.worst_case_seconds))
			extra.push(E('p', {}, [
				_('It is never allowed to take more than %s.')
					.format(durationLabel(plan.worst_case_seconds))
			]));
		/* The second subscription is a different operator, and therefore a
		 * different APN. Saying so is the difference between a slot change and
		 * a slot change that silently leaves the wrong settings behind -- the
		 * defect the operation was given a reconcile to fix. */
		if (plan.reconciles === true)
			extra.push(E('p', {}, [
				_('The other slot is a different subscription, so the APN is worked out again for it afterwards.')
			]));
		extra.push(E('p', { 'class': 'apn-confirm-scope' }, [
			_('This runs against this one modem.')
		]));
		self.showConfirmation(_('Use the other SIM slot'), body, extra, false, function() {
			self.startSlotSwitch(subject, slot);
		});
	},

	startSlotSwitch: function(subject, slot) {
		var self = this;
		self.setControlsBusy(true);
		return call(modemControlCommand,
			[ 'slot-switch', subject.modem.modem_id, String(slot) ]).then(function(result) {
			if (!result.accepted && !result.busy)
				throw new Error(result.message || _('The operation could not be started'));
			self.modemPollPending = true;
		}).catch(function(error) {
			/* As everywhere: a launch answer that was lost is not evidence
			 * that nothing started. */
			self.modemPollPending = true;
			ui.addNotification(null, E('p', {}, [ error.message ]), 'error');
		});
	},

	startModemAction: function(subject, verb) {
		var self = this;
		self.setControlsBusy(true);
		return call(modemControlCommand, [ verb, subject.modem.modem_id ]).then(function(result) {
			if (!result.accepted && !result.busy)
				throw new Error(result.message || _('The operation could not be started'));
			/* Accepted or safely coalesced: polling decides when it is over. */
			self.modemPollPending = true;
		}).catch(function(error) {
			/* The launch answer may have been lost after the job was accepted,
			 * so this never reports success or failure on its own. */
			self.modemPollPending = true;
			ui.addNotification(null, E('p', {}, [ error.message ]), 'error');
		});
	},

	startAction: function(action, target) {
		var self = this;
		self.engineBusy = true;
		self.setControlsBusy(true);
		var args = target ? [ action, target ] : [ action ];
		return call(controlCommand, args).then(function(result) {
			if (!result.accepted && !result.busy)
				throw new Error(result.message || _('The operation could not be started'));
			self.actionPollPending = true;
		}).catch(function(error) {
			/* As elsewhere: a lost launch answer keeps polling rather than
			 * reporting a result it does not have. */
			self.actionPollPending = true;
			ui.addNotification(null, E('p', {}, [ error.message ]), 'error');
		});
	},

	setControlsBusy: function(busy) {
		(this.controls || []).forEach(function(node) { node.disabled = !!busy; });
	},

	/* ---- manual APN entry ------------------------------------------------------ */

	/* Manual entry is the fallback for a SIM the database does not cover, so it
	 * lives behind a control rather than sitting expanded on the page asking
	 * every user to fill in something almost nobody should need. */
	openManualApn: function(subject) {
		var self = this;
		if (self.subjectBusy(subject) || !subject.targetId)
			return;

		self.manualSubject = subject;
		self.manualApn = E('input', { 'type': 'text', 'class': 'cbi-input-text',
			'data-apn-control': 'apply-manual', 'placeholder': _('internet.example') }, []);
		self.manualUsername = E('input', { 'type': 'text', 'class': 'cbi-input-text',
			'data-apn-control': 'apply-manual' }, []);
		self.manualPassword = E('input', { 'type': 'password', 'class': 'cbi-input-password',
			'data-apn-control': 'apply-manual' }, []);
		self.manualAuth = E('select', { 'class': 'cbi-input-select', 'data-apn-control': 'apply-manual' }, [
			E('option', { 'value': '' }, [ _('Not specified') ]),
			E('option', { 'value': 'none' }, [ _('None') ]),
			E('option', { 'value': 'pap' }, [ 'PAP' ]),
			E('option', { 'value': 'chap' }, [ 'CHAP' ]),
			E('option', { 'value': 'pap-or-chap' }, [ _('PAP or CHAP') ])
		]);
		self.manualIpType = E('select', { 'class': 'cbi-input-select', 'data-apn-control': 'apply-manual' }, [
			E('option', { 'value': '' }, [ _('Not specified') ]),
			E('option', { 'value': 'ipv4' }, [ 'IPv4' ]),
			E('option', { 'value': 'ipv6' }, [ 'IPv6' ]),
			E('option', { 'value': 'ipv4v6' }, [ _('IPv4 and IPv6') ])
		]);

		self.manualDialog = E('div', { 'class': 'apn-manual-dialog' }, [
			E('p', {}, [
				_('Use this when the database has no profile for your SIM, or your operator issued you a private one. The profile is tested like any other: the current one is saved first, real Internet access is verified, and a profile that does not work is undone.')
			]),
			E('p', { 'class': 'apn-confirm-scope' }, [ _('This runs against %s only.').format(subject.section) ]),
			table([
				row(_('APN'), self.manualApn),
				row(_('Username'), self.manualUsername),
				row(_('Password'), self.manualPassword),
				row(_('Authentication'), self.manualAuth),
				row(_('IP family'), self.manualIpType)
			]),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn',
					'type': 'button',
					'data-apn-nav': 'cancel',
					'click': function() { self.closeManualApn(); }
				}, [ _('Cancel') ]),
				' ',
				E('button', {
					'class': 'btn cbi-button-action important',
					'type': 'button',
					'data-apn-nav': 'confirm',
					'click': function() { self.confirmManualApn(); }
				}, [ _('Apply this APN') ])
			])
		]);

		self.openDialog(_('Enter an APN by hand'), self.manualDialog);
	},

	/* The secret leaves no trace behind the dialog: the field is overwritten,
	 * the dialog's own nodes are detached, and no reference to the value
	 * outlives the handler that used it. */
	closeManualApn: function() {
		if (this.manualPassword)
			this.manualPassword.value = '';
		if (this.manualDialog)
			dom.content(this.manualDialog, []);
		this.manualApn = null;
		this.manualUsername = null;
		this.manualPassword = null;
		this.manualAuth = null;
		this.manualIpType = null;
		this.manualDialog = null;
		this.manualSubject = null;
		ui.hideModal();
		this.closeDialog();
	},

	manualApnValues: function() {
		return {
			apn: (this.manualApn && this.manualApn.value || '').trim(),
			username: (this.manualUsername && this.manualUsername.value || '').trim(),
			password: this.manualPassword && this.manualPassword.value || '',
			auth: this.manualAuth && this.manualAuth.value || '',
			ip_type: this.manualIpType && this.manualIpType.value || ''
		};
	},

	/* Mirrors the engine's rules so a mistake is reported here instead of
	 * surfacing much later as an opaque bearer rejection. The engine still
	 * validates; this never becomes the only check. */
	manualApnError: function(values) {
		if (!values.apn)
			return _('Enter an APN.');
		if (!/^[A-Za-z0-9._-]+$/.test(values.apn))
			return _('The APN may only contain letters, digits, dot, underscore and hyphen.');
		if (values.apn.length > 63)
			return _('The APN is longer than 63 characters.');
		if (values.username && !values.password)
			return _('A username was given without a password.');
		if (values.password && !values.username)
			return _('A password was given without a username.');
		return null;
	},

	confirmManualApn: function() {
		var self = this;
		var subject = self.manualSubject;
		if (!subject || self.subjectBusy(subject))
			return;

		var values = self.manualApnValues();
		var error = self.manualApnError(values);
		if (error) {
			/* Refused before any wrapper call: the dialog stays open so the
			 * entry can be corrected, and the error never echoes the value. */
			ui.addNotification(null, E('p', {}, [ error ]), 'warning');
			return;
		}

		self.showConfirmation(_('Apply this APN'),
			_('The APN %s will be applied to %s and tested. Mobile connectivity through it will be interrupted briefly.')
				.format(values.apn, subject.section),
			[ E('p', {}, [ _('If it does not provide real Internet access, the previous profile is restored automatically.') ]),
				E('p', { 'class': 'apn-confirm-scope' }, [ _('This runs against %s only.').format(subject.section) ]) ],
			false, function() { self.startManualApn(subject, values); },
			/* This confirmation replaced the form that holds the password, so
			 * backing out of it is the end of that form: the field is cleared
			 * and nothing keeps a reference to what was typed into it. */
			function() {
				self.closeManualApn();
				values.password = '';
			});
	},

	startManualApn: function(subject, values) {
		var self = this;
		if (!subject.targetId) {
			ui.addNotification(null, E('p', {}, [ _('This connection has no target to act on.') ]), 'error');
			return;
		}

		/* The profile travels as ubus call parameters and reaches the wrapper
		 * on its standard input. It is in no command line at any hop, and the
		 * environment it once used is a channel rpcd refuses outright -- which
		 * is why this form could never have worked before. */
		self.engineBusy = true;
		self.setControlsBusy(true);

		function settle() {
			/* On success and on failure alike. */
			self.closeManualApn();
			values.password = '';
		}

		return callApplyManual(subject.targetId, values.apn, values.username || '',
			values.password || '', values.auth || '', values.ip_type || ''
		).then(secretResult).then(function(result) {
			settle();
			self.actionPollPending = true;
			if (!result.accepted && !result.busy)
				throw new Error(result.message || _('The operation could not be started'));
		}).catch(function(error) {
			settle();
			self.actionPollPending = true;
			ui.addNotification(null, E('p', {}, [ error.message ]), 'error');
		});
	},

	/* ---- navigation ------------------------------------------------------------- */

	/* Navigating changes no router state. Opening a workspace, an area or the
	 * database view issues no call at all: everything it needs is already
	 * held, and it re-renders from that. */
	navigate: function(route, options) {
		options = options || {};
		this.route = this.normaliseRoute(route);
		this.userEditing = false;
		if (!options.fromHistory)
			this.pushAddress(options.replace === true);
		this.renderRoute();
	},

	normaliseRoute: function(route) {
		route = route || {};
		var area = routerAreas.indexOf(route.area) !== -1 ? route.area : 'overview';
		var subject = route.subject && this.subjectByKey(route.subject) ? route.subject : null;
		var workspace = workspaceAreas.indexOf(route.workspace) !== -1 ? route.workspace : 'connection';
		/* With exactly one card the page opens that card's workspace directly:
		 * a one-modem router must not pay a click to reach everything, and a
		 * two-modem router must never be handed one modem's page as though it
		 * were the router's. */
		if (area === 'overview' && !subject && (this.subjects || []).length === 1)
			subject = this.subjects[0].key;
		return { area: area, subject: subject, workspace: workspace };
	},

	/* The address carries a modem_id or a section name, both of which already
	 * appear in the argv of every action on them. An EID, an ICCID, an IMSI or
	 * any suffix of one never reaches it. */
	addressOf: function(route) {
		if (route.area === 'database')
			return '#database';
		if (route.area === 'settings')
			return '#settings';
		if (!route.subject)
			return '#overview';
		var subject = this.subjectByKey(route.subject);
		if (!subject)
			return '#overview';
		var key = subject.kind === 'modem'
			? 'modem=' + encodeURIComponent(subject.modem.modem_id)
			: 'target=' + encodeURIComponent(subject.section);
		return '#%s/%s'.format(key, route.workspace);
	},

	routeFromAddress: function(hash) {
		var value = (hash || '').replace(/^#/, '');
		if (value === 'database' || value === 'settings')
			return { area: value, subject: null, workspace: 'connection' };
		var match = /^(modem|target)=([^/]*)(?:\/(.*))?$/.exec(value);
		if (!match)
			return { area: 'overview', subject: null, workspace: 'connection' };
		var key = match[1] === 'modem'
			? 'modem:' + decodeURIComponent(match[2])
			: 'target:' + decodeURIComponent(match[2]);
		return { area: 'overview', subject: key, workspace: match[3] || 'connection' };
	},

	pushAddress: function(replace) {
		var host = browserWindow();
		if (!host || !host.history || typeof host.history.pushState !== 'function')
			return;
		var address = this.addressOf(this.route);
		if (replace && typeof host.history.replaceState === 'function')
			host.history.replaceState(null, '', address);
		else
			host.history.pushState(null, '', address);
	},

	/* ---- rendering --------------------------------------------------------------- */

	/* Where the keyboard is, in terms that survive a re-render: which control,
	 * and which of the several nodes that draw the same control. */
	focusedPosition: function() {
		var host = browserWindow();
		var active = host && host.document ? host.document.activeElement : null;
		var key = active ? focusKeyOf(active) : null;
		if (!key)
			return null;
		/* Only a node this page drew: focus that is somewhere else on the
		 * router's page is not ours to move or to restore. */
		var ordinal = 0;
		var nodes = focusableNodes(this.page);
		for (var index = 0; index < nodes.length; index++) {
			if (nodes[index] === active)
				return { key: key, ordinal: ordinal };
			if (focusKeyOf(nodes[index]) === key)
				ordinal++;
		}
		return null;
	},

	/* Put it back on the node that means the same thing. A poll never moves
	 * focus, and re-rendering an area is how a poll would move it. */
	restoreFocus: function(position) {
		if (!position)
			return;
		var ordinal = 0;
		var nodes = focusableNodes(this.page);
		for (var index = 0; index < nodes.length; index++) {
			if (focusKeyOf(nodes[index]) !== position.key)
				continue;
			if (ordinal === position.ordinal) {
				if (typeof nodes[index].focus === 'function')
					nodes[index].focus();
				return;
			}
			ordinal++;
		}
	},

	renderRoute: function() {
		var self = this;
		if (!self.page)
			return;
		var focused = self.focusedPosition();
		self.controls = [];
		self.policySelect = null;

		var action = self.documents && self.documents.action;
		self.engineBusy = !!(action && !action.error && action.busy);

		(self.routerPanels || []).forEach(function(panel) {
			var active = panel.name === self.route.area;
			panel.node.style.display = active ? '' : 'none';
			panel.node.setAttribute('aria-hidden', active ? 'false' : 'true');
		});
		(self.routerTabs || []).forEach(function(entry) {
			var active = entry.name === self.route.area;
			entry.node.setAttribute('aria-selected', active ? 'true' : 'false');
			entry.node.className = 'btn cbi-button apn-router-tab' +
				(active ? ' cbi-button-action apn-router-active' : '');
		});

		if (self.route.area === 'overview') {
			var subject = self.route.subject ? self.subjectByKey(self.route.subject) : null;
			dom.content(self.overviewBox, self.overviewNodes());
			dom.content(self.workspaceBox, subject ? self.workspaceNodes(subject) : []);
		}
		else if (self.route.area === 'database')
			dom.content(self.databaseBox, self.databaseNodes());
		else if (self.route.area === 'settings')
			self.renderSettingsArea();

		if (self.engineBusy)
			self.setControlsBusy(true);

		self.restoreFocus(focused);
	},

	/* Built once, on first entry, and never again -- the form holds values a
	 * user has typed. Until the reads it genuinely needs have answered it shows
	 * `pending` rather than a form with a target list that is missing entries,
	 * because a form built from half an answer would then have to be rebuilt,
	 * which is the one thing this panel may not do. */
	renderSettingsArea: function() {
		var self = this;
		if (self.settingsRendered || self.settingsPending)
			return;
		if (self.routerPending()) {
			dom.content(self.settingsBox, [
				pendingLine(_('the settings this program uses'))
			]);
			return;
		}
		self.settingsPending = true;
		var m = self.settingsMap();
		self.settingsPromise = m.render().then(function(mapNode) {
			self.settingsPending = false;
			self.settingsRendered = true;
			dom.content(self.settingsBox, [ mapNode ]);
		}).catch(function() {
			self.settingsPending = false;
			dom.content(self.settingsBox, [
				unknownLine(_('The settings form'), _('Reload the page to try again.'))
			]);
		});
	},

	everyStatusRead: function() {
		var self = this;
		var ids = self.targetIds(self.documents);
		for (var i = 0; i < ids.length; i++) {
			if (!self.documents.statusRead[ids[i]])
				return false;
		}
		return true;
	},

	refreshDocuments: function() {
		var self = this;
		return self.loadDocuments().then(function(documents) {
			self.documents = documents;
			self.subjects = self.buildSubjects(documents);
			self.route = self.normaliseRoute(self.route);
			self.modemPollPending = self.subjects.some(function(subject) {
				return !!(subject.operation && !subject.operation.error && subject.operation.busy);
			});
			/* A poll never replaces a form the user has typed into. */
			if (!self.userEditing)
				self.renderRoute();
		});
	},

	/* Everything about an operation that this page draws. A poll whose answer
	 * is identical to the last one has nothing to redraw, and redrawing anyway
	 * is not free: it replaces every node, which takes the keyboard with it. */
	actionSignature: function(action) {
		if (!action)
			return 'none';
		if (action.error)
			return 'error\u0001' + action.error;
		return [ action.busy ? '1' : '0', action.state || '', action.action || '',
			action.message || '', action.target_id || '' ].join('\u0001');
	},

	/* Poll only cheap action state continuously. A full document refresh is
	 * paid when an operation ends, when a modem operation is in flight, or
	 * when the page was loaded while a modem was still returning. */
	refreshAction: function() {
		var self = this;
		return call(queryCommand, [ 'action-status' ]).then(function(action) {
			var wasBusy = self.engineBusy;
			var signature = self.actionSignature(action);
			var changed = signature !== self.actionRendered;
			self.actionRendered = signature;
			if (self.documents)
				self.documents.action = action;
			self.engineBusy = !!(action && !action.error && action.busy);
			if (wasBusy && !self.engineBusy) {
				self.actionPollPending = false;
				return self.refreshDocuments();
			}
			if (!self.engineBusy && self.actionPollPending) {
				self.actionPollCount = (self.actionPollCount || 0) + 1;
				if (self.actionPollCount >= 5) {
					self.actionPollCount = 0;
					self.actionPollPending = false;
					return self.refreshDocuments();
				}
			}
			if (changed && !self.userEditing)
				self.renderRoute();
		}).catch(function() {
			/* A transient polling failure is not evidence that a long-running
			 * operation ended. Keep the controls as they are until the core
			 * says otherwise. */
		});
	},

	render: function() {
		var self = this;
		var documents = self.emptyDocuments();

		self.documents = documents;
		self.subjects = [];
		self.overviewExpanded = false;
		self.userEditing = false;
		self.controls = [];
		self.modemPollPending = false;
		self.actionPollPending = false;
		self.actionPollCount = 0;
		self.esimPending = {};
		self.esimPollPending = false;
		self.esimRefusals = {};
		self.esimCardPending = {};
		self.esimSettling = {};
		self.esimSentHere = {};
		self.slotProbePending = {};
		self.actionRendered = self.actionSignature(documents.action);
		self.hardwareIntegration = '';
		self.settingsRendered = false;
		self.settingsPending = false;

		return Promise.resolve().then(function() {
			self.overviewBox = E('div', { 'class': 'apn-overview' }, []);
			self.workspaceBox = E('div', { 'class': 'apn-workspace-host' }, []);
			self.databaseBox = E('div', { 'class': 'apn-database' }, []);
			/* The settings form is built on first entry to its own area and
			 * never rebuilt afterwards: it holds values a user has typed, and
			 * nothing on this page may throw those away. Building it here would
			 * mean waiting, before the page exists at all, for a read that only
			 * this one area needs. */
			self.settingsBox = E('div', { 'class': 'apn-settings' }, []);

			var areas = [
				{ name: 'overview', label: _('Overview'), nodes: [ self.overviewBox, self.workspaceBox ] },
				{ name: 'database', label: _('Provider database'), nodes: [ self.databaseBox ] },
				{ name: 'settings', label: _('Program settings'), nodes: [ self.settingsBox ] }
			];

			self.routerPanels = [];
			self.routerTabs = [];
			var panels = areas.map(function(area) {
				var panel = E('div', { 'class': 'cbi-section apn-card apn-panel', 'role': 'tabpanel' }, area.nodes);
				self.routerPanels.push({ name: area.name, node: panel });
				return panel;
			});
			var tabs = areas.map(function(area) {
				var button = E('button', {
					'class': 'btn cbi-button apn-router-tab',
					'type': 'button',
					'role': 'tab',
					'data-apn-nav': 'router-area',
					'data-apn-area': area.name,
					'click': function(ev) {
						ev.preventDefault();
						self.navigate({ area: area.name, subject: self.route.subject,
							workspace: self.route.workspace });
					}
				}, [ area.label ]);
				self.routerTabs.push({ name: area.name, node: button });
				return button;
			});

			self.page = E('div', { 'class': 'apn-autoconfig-page' }, [
				E('style', { 'type': 'text/css' }, [ self.styleText() ]),
				E('h2', {}, [ _('Mobile connectivity') ]),
				E('div', { 'class': 'apn-router-tabs', 'role': 'tablist' }, tabs)
			].concat(panels));

			var host = browserWindow();
			var initial = host && host.location ? self.routeFromAddress(host.location.hash) : {};
			self.route = self.normaliseRoute(initial);
			self.renderRoute();
			self.pushAddress(true);

			/* Back returns to where the user was and starts nothing: it
			 * re-renders from state already held. */
			if (host && typeof host.addEventListener === 'function')
				host.addEventListener('popstate', function() {
					self.navigate(self.routeFromAddress(host.location ? host.location.hash : ''),
						{ fromHistory: true });
				});

			poll.add(function() { return self.refreshAction(); }, 2);
			poll.add(function() {
				return self.modemPollPending ? self.refreshDocuments() : Promise.resolve();
			}, 3);
			/* The eSIM coordinator keeps its own operation state, so a running
			 * takeover, switch, download or deletion is followed here. It runs
			 * only while one is pending and it reads coordinator state, never a
			 * card: `action-start` returns immediately and the outcome is
			 * resolved by polling, which is also what makes a lost launch
			 * answer recoverable instead of invented. */
			poll.add(function() {
				return self.esimPollPending ? self.refreshEsimOperation() : Promise.resolve();
			}, 3);
			/* Five seconds rather than two, because hardware changes are rare
			 * and this is a second process spawn per cycle. It is the only
			 * thing on the page that notices a modem arriving or leaving while
			 * nothing else is happening. */
			poll.add(function() { return self.refreshHardwareGeneration(); }, 5);

			/* The page is on screen; now buy the levels, in the background and
			 * out of the way of the paint that has already happened. The
			 * promise is kept so a test can wait for the staged reads without
			 * guessing how many turns of the queue they take. */
			self.fillPromise = self.fillDocuments();

			return self.page;
		});
	},

	/* Level 0, then level 1. Each arrival re-renders, so a card appears as soon
	 * as it is known to exist and completes as soon as its own status answers
	 * -- the AT-dial target is three times the cost of the ModemManager one and
	 * there is no reason for the cheap card to wait behind it. */
	fillDocuments: function() {
		var self = this;
		/* Level 0 is observable on its own, because "the cards exist" and "each
		 * card knows what it is doing" are different moments and a test that
		 * cannot tell them apart cannot check that they are. */
		self.routerPromise = self.loadRouterDocuments();
		return self.routerPromise.then(function(base) {
			self.documents.targets = base.targets;
			self.documents.action = base.action;
			self.documents.database = base.database;
			self.documents.inventory = base.inventory;
			self.documents.routerRead = true;
			self.hardwareIntegration = self.readHardwareIntegration(self.documents);
			self.actionRendered = self.actionSignature(base.action);
			self.engineBusy = !!(base.action && !base.action.error && base.action.busy);
			self.subjects = self.buildSubjects(self.documents);
			self.route = self.normaliseRoute(self.route);
			self.modemPollPending = self.subjects.some(function(subject) {
				return !!(subject.operation && !subject.operation.error && subject.operation.busy);
			});
			if (!self.userEditing)
				self.renderRoute();

			/* One at a time, and each one drawn as it lands. See
			 * `loadRouterDocuments` for why a queue beats `Promise.all` here:
			 * the calls are serialised underneath regardless, so issuing them
			 * together buys no time and costs every early answer. */
			return self.sequence(self.targetIds(self.documents).map(function(id) {
				return function() {
					return self.loadTargetStatus(id).then(function(status) {
						self.documents.statuses[id] = status;
						self.documents.statusRead[id] = true;
						self.subjects = self.buildSubjects(self.documents);
						if (!self.hardwareIntegration)
							self.hardwareIntegration = self.readHardwareIntegration(self.documents);
						if (!self.userEditing)
							self.renderRoute();
					});
				};
			}));
		}).catch(function() {
			/* A failure here is already rendered: every read this method makes
			 * resolves to an error document rather than rejecting, so there is
			 * nothing to report that the areas are not showing. */
		});
	},

	/* A modem that is unplugged must stop being on screen, and a modem that
	 * arrives must appear, without anybody reloading the window.
	 *
	 * Nothing else on the page can notice either. The two-second poll reads the
	 * engine's operation state, which says nothing about which modems exist,
	 * and the document refresh beside it runs only while a modem operation is
	 * running. Observed on the reference router 2026-09-02: a modem detached
	 * from the bus kept its card, its "Connected" line and a Disconnect button
	 * offering an operation on hardware that was gone.
	 *
	 * The fix is not to re-read the inventory on a timer -- that is the 1.5 s
	 * scan P7 exists to stop paying for. It is to ask a question cheap enough
	 * to ask often, and to pay for the scan only when the answer changes.
	 *
	 * An older backend has no such verb. That is not a hardware change and must
	 * not become a refresh loop: the failure is remembered and asked again, and
	 * the page behaves exactly as it did before this existed. */
	refreshHardwareGeneration: function() {
		var self = this;
		return call(modemQueryCommand, [ 'hardware-generation' ]).then(function(answer) {
			var generation = answer && !answer.error ? answer.generation : null;
			if (typeof generation !== 'string')
				return;
			var previous = self.hardwareGeneration;
			self.hardwareGeneration = generation;
			/* The first answer establishes the baseline; it is not a change. */
			if (previous === undefined || previous === generation)
				return;
			return self.refreshDocuments();
		}).catch(function() {
			/* A backend that does not publish it, or a read that failed. Either
			 * way there is nothing to compare and nothing to redraw. */
		});
	},

	/* Whether every read an area needs has answered. `pending` is the state
	 * between asking and knowing, and it is not `unknown`: see pendingLine. */
	routerPending: function() {
		return !(this.documents && this.documents.routerRead);
	},

	statusPending: function(subject) {
		if (!subject || !subject.targetId)
			return false;
		return !(this.documents && this.documents.statusRead[subject.targetId]);
	},

	/* A router fact, so it is read from the router-scoped document that costs
	 * a fifth of a second. The per-target statuses remain the fallback and
	 * nothing else: a backend older than this field still answers there, and an
	 * absent field in both is unknown rather than "no board". */
	readHardwareIntegration: function(documents) {
		var targets = documents && documents.targets;
		if (targets && !targets.error && targets.hardware_integration)
			return targets.hardware_integration;

		var statuses = documents && documents.statuses || {};
		var found = '';
		Object.keys(statuses).forEach(function(id) {
			var status = statuses[id];
			if (!found && status && !status.error && status.hardware_integration)
				found = status.hardware_integration;
		});
		return found;
	},

	settingsMap: function() {
		var self = this;
		var targets = self.documents && self.documents.targets;
		var m = new form.Map('apn-autoconfig', null,
			_('How the program behaves on its own, without anybody looking at this page.'));
		var s = m.section(form.NamedSection, 'main', 'apn_autoconfig', _('Configuration'));
		var o;

		s.tab('general', _('General'));
		s.tab('advanced', _('Advanced'));

		o = s.taboption('general', form.Flag, 'autostart', _('Automatic reconciliation at boot'));
		o.default = o.disabled;
		o.rmempty = false;
		o.description = _('After boot, wait for the configured delay and reconcile the current SIM and mobile profile. The service remains inert when this option is disabled.');

		if (self.hardwareIntegration) {
			o = s.taboption('general', form.Flag, 'button_enabled', _('Enable WH3000 modem-reset button'));
			o.default = o.disabled;
			o.rmempty = false;
			o.description = _('Provided by the separately installed Huasifei WH3000 board integration. Releasing BTN_0 power-cycles the modem and then reconciles the APN.');
		}

		o = s.taboption('general', form.ListValue, 'interface', _('Mobile target'));
		o.value('auto', _('Automatic (every writable target)'));
		var configuredTarget = typeof uci.get === 'function'
			? uci.get('apn-autoconfig', 'main', 'interface') : 'auto';
		var configuredTargetListed = configuredTarget === 'auto';
		if (targets && Array.isArray(targets.targets))
			targets.targets.forEach(function(target) {
				var capabilityLabel = target.capabilities.profile_apply ? _('APN supported') :
					target.capabilities.identity ? _('read-only identity') : _('inventory only');
				var validationLabel = target.validation_state && target.validation_state !== 'none'
					? ', %s'.format(target.validation_state) : '';
				o.value(target.interface, '%s — %s (%s)'.format(target.interface, target.protocol,
					capabilityLabel + validationLabel));
				if (target.interface === configuredTarget)
					configuredTargetListed = true;
			});
		if (configuredTarget && !configuredTargetListed)
			o.value(configuredTarget, _('%s — currently configured, not discovered').format(configuredTarget));
		o.default = 'auto';
		o.rmempty = false;
		o.description = _('Automatic mode looks after every cellular target it can write an APN profile to, which is normally what you want with more than one modem. Choosing one target restricts the program to it, and the others are then left entirely alone.');

		o = s.taboption('general', form.Value, 'device', _('Mobile data device'));
		o.default = 'wwan0';
		o.rmempty = false;
		o.datatype = 'uciname';
		o.description = _('Fallback used only when netifd does not report an effective layer-3 device.');

		o = s.taboption('general', form.ListValue, 'use_mwan3', _('mwan3-aware connectivity test'));
		o.value('auto', _('Automatic'));
		o.value('always', _('Always use mwan3'));
		o.value('never', _('Never use mwan3'));
		o.default = 'auto';

		if (self.hardwareIntegration) {
			o = s.taboption('advanced', form.Value, 'button_name', _('Button event name'));
			o.default = 'BTN_0';
			o.rmempty = false;

			o = s.taboption('advanced', form.Value, 'modem_power_path', _('Modem power GPIO value path'));
			o.default = '/sys/class/gpio/modem_power/value';
			o.rmempty = false;
			o.description = _('Huasifei board integration path. This is not a raw GPIO pin number.');

			o = s.taboption('advanced', form.Value, 'modem_power_off_seconds', _('Power-off duration'));
			o.default = '5';
			o.datatype = 'uinteger';
			o.rmempty = false;
		}

		o = s.taboption('advanced', form.Value, 'modem_wait_seconds', _('Maximum modem return wait'));
		o.default = '90';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'wait_seconds', _('Maximum interface-up wait'));
		o.default = '35';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'registration_wait_seconds', _('Maximum registration wait'));
		o.default = '30';
		o.datatype = 'uinteger';
		o.rmempty = false;
		o.description = _('Wait for home or roaming registration before changing any APN profile.');

		o = s.taboption('advanced', form.Value, 'test_url', _('Connectivity test URL'));
		o.default = 'https://connectivitycheck.gstatic.com/generate_204';
		o.rmempty = false;

		return m;
	},

	styleText: function() {
		return '.apn-autoconfig-page .apn-card{margin:0 0 1rem 0!important;padding:1rem}' +
			'.apn-autoconfig-page .apn-card>h3{margin-top:0}' +
			'.apn-autoconfig-page .apn-router-tabs{display:flex;flex-wrap:wrap;gap:.5rem;margin-bottom:1rem}' +
			'.apn-autoconfig-page .apn-area-tabs{display:flex;flex-wrap:wrap;gap:.5rem;margin:1rem 0}' +
			'.apn-autoconfig-page .apn-overview-head{display:flex;flex-wrap:wrap;align-items:center;' +
				'justify-content:space-between;gap:.5rem}' +
			'.apn-autoconfig-page .apn-overview-head h3{margin:0}' +
			'.apn-autoconfig-page .apn-cards{display:flex;flex-direction:column;gap:.75rem;margin-top:.75rem}' +
			'.apn-autoconfig-page .apn-card-subject{border:1px solid rgba(128,128,128,.35);border-radius:4px;' +
				'padding:.75rem 1rem}' +
			'.apn-autoconfig-page .apn-card-head{display:flex;flex-wrap:wrap;align-items:center;' +
				'justify-content:space-between;gap:.5rem}' +
			'.apn-autoconfig-page .apn-card-name{font-weight:600}' +
			'.apn-autoconfig-page .apn-card-facts{display:flex;flex-wrap:wrap;gap:.35rem;margin-top:.35rem}' +
			'.apn-autoconfig-page .apn-card-note,.apn-autoconfig-page .apn-area-note{margin:.35rem 0 0 0;opacity:.8}' +
			'.apn-autoconfig-page .apn-strip{display:flex;flex-wrap:wrap;gap:1rem 2rem;padding:.75rem 1rem;' +
				'margin-bottom:1rem;border:1px solid rgba(128,128,128,.35);border-radius:4px}' +
			'.apn-autoconfig-page .apn-strip-item{display:flex;flex-direction:column;min-width:9rem}' +
			'.apn-autoconfig-page .apn-strip-label{font-size:85%;opacity:.7}' +
			'.apn-autoconfig-page .apn-strip-value{font-weight:600}' +
			'.apn-autoconfig-page .apn-tone-good{color:#2d8a43}' +
			'.apn-autoconfig-page .apn-tone-bad{color:#b11}' +
			'.apn-autoconfig-page .apn-tone-warn{color:#b58100}' +
			'.apn-autoconfig-page .apn-tone-busy{color:#25709c}' +
			/* Neither demoted result state is an error, so neither borrows the
			 * failure colour — and they are told apart from each other as well:
			 * a previous result is settled and merely old, an unconfirmed one
			 * is a question. */
			'.apn-autoconfig-page .apn-verdict-previous{opacity:.65;font-weight:400}' +
			'.apn-autoconfig-page .apn-verdict-unknown{opacity:.65;font-weight:400;font-style:italic}' +
			'.apn-autoconfig-page .apn-verdict-none{opacity:.65;font-weight:400}' +
			'.apn-autoconfig-page .apn-demoted{margin-top:.75rem}' +
			'.apn-autoconfig-page .apn-demoted h5{margin:0 0 .25rem 0}' +
			'.apn-autoconfig-page .apn-demoted-previous .apn-demoted-text{opacity:.7}' +
			'.apn-autoconfig-page .apn-demoted-unknown .apn-demoted-text{opacity:.7;font-style:italic}' +
			'.apn-autoconfig-page .apn-demoted-note{margin-top:.25rem;font-size:90%;opacity:.75}' +
			/* A promise and a refusal are different sentences and are styled
			 * as neither an error nor a control. */
			'.apn-autoconfig-page .apn-planned{opacity:.75;font-style:italic;margin:.35rem 0}' +
			/* Its own look, deliberately not the unknown line's: one says a read
			 * failed, the other says it has not answered yet. */
			'.apn-autoconfig-page .apn-pending-line{opacity:.7;margin:.35rem 0}' +
			'.apn-autoconfig-page .apn-unknown-line{opacity:.85;margin:.35rem 0}' +
			'.apn-autoconfig-page .apn-refusal-line{opacity:.85;margin:.35rem 0}' +
			'.apn-autoconfig-page .apn-label strong{font-weight:600}' +
			'.apn-autoconfig-page .apn-help-label{display:inline-flex;align-items:center;gap:.4em}' +
			'.apn-autoconfig-page .apn-help-toggle{padding:0 .5em;line-height:1.4;min-width:1.8em}' +
			'.apn-autoconfig-page .apn-help-text{margin:.4rem 0 0 0;font-weight:400;opacity:.85}' +
			'.apn-autoconfig-page .apn-details{margin-top:.75rem}' +
			'.apn-autoconfig-page .apn-details summary{cursor:pointer;font-weight:600;padding:.35rem 0}' +
			'.apn-autoconfig-page .apn-button-row{display:flex;flex-wrap:wrap;gap:.5rem;margin-top:.75rem}' +
			'.apn-autoconfig-page .apn-policy-controls{display:flex;flex-wrap:wrap;align-items:center;' +
				'gap:.5rem;margin-top:.75rem}' +
			'.apn-autoconfig-page .apn-state-good{color:#2d8a43;font-weight:600}' +
			'.apn-autoconfig-page .apn-state-bad{color:#b11;font-weight:600}' +
			'.apn-autoconfig-page .apn-confirm-scope{font-weight:600}' +
			/* One column below 600px: cards stack, label/value pairs stack, and
			 * the area tabs become a full-width list. Nothing essential is
			 * behind hover at any width and nothing needs sideways scrolling. */
			'@media(max-width:600px){.apn-autoconfig-page .apn-card{padding:.75rem}' +
				'.apn-autoconfig-page .apn-card-head{align-items:flex-start;flex-direction:column}' +
				'.apn-autoconfig-page .apn-area-tabs,.apn-autoconfig-page .apn-router-tabs' +
					'{flex-direction:column;align-items:stretch}' +
				'.apn-autoconfig-page .apn-table .apn-label,' +
				'.apn-autoconfig-page .apn-table .apn-value{display:block;width:auto!important}' +
				'.apn-autoconfig-page .apn-strip-item{min-width:100%}}';
	}
});
