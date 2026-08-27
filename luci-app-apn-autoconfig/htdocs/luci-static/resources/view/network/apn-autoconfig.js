'use strict';
'require view';
'require form';
'require fs';
'require uci';
'require ui';
'require poll';
'require dom';

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

function call(command, args, env) {
	return fs.exec(command, args, env).then(function(result) {
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

		if (result.code !== 0)
			throw new Error((result.stderr || result.stdout || _('Command failed')).trim());
		if (parsed == null)
			throw new Error(_('The APN helper returned invalid JSON'));
		return parsed;
	});
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
		connection_owned: modem.connection_owned
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

var workspaceAreas = [ 'connection', 'sim', 'apn', 'modem', 'diagnostics' ];
var routerAreas = [ 'overview', 'database', 'settings' ];

return view.extend({
	/* ---- loading ------------------------------------------------------- */

	/* One document set, read once. The status document is per target because a
	 * router with two modems has two answers, and v1's single "selected
	 * target" status is exactly the shape that could not carry them. */
	loadDocuments: function() {
		return call(queryCommand, [ 'targets' ])
			.catch(function(error) { return { error: error.message }; })
			.then(function(targets) {
				var list = targets && !targets.error && Array.isArray(targets.targets)
					? targets.targets : [];
				return Promise.all([
					targets,
					Promise.all(list.map(function(target) {
						return call(queryCommand, [ 'status', target.id ])
							.catch(function(error) { return { error: error.message }; })
							.then(function(status) { return { id: target.id, status: status }; });
					})),
					call(queryCommand, [ 'action-status' ]).catch(function(error) { return { error: error.message }; }),
					call(queryCommand, [ 'database-status' ]).catch(function(error) { return { error: error.message }; }),
					call(modemQueryCommand, [ 'inventory' ]).catch(function(error) { return { error: error.message }; })
						.then(function(inventory) {
							var modems = inventory && Array.isArray(inventory.modems) ? inventory.modems : [];
							if (!modems.length)
								return inventory;
							/* The plan arrives with the record. Only the
							 * operation state still needs a call of its own,
							 * because it is a coordinator fact rather than an
							 * inventory one. */
							return Promise.all(modems.map(function(modem) {
								modem.plan = planOf(modem);
								return call(modemQueryCommand, [ 'action-status', modem.modem_id ])
									.catch(function(error) { return { error: error.message }; })
									.then(function(operation) { modem.operation = operation; });
							})).then(function() { return inventory; });
						})
				]);
			}).then(function(values) {
				var statuses = {};
				values[1].forEach(function(entry) { statuses[entry.id] = entry.status; });
				return {
					targets: values[0],
					statuses: statuses,
					action: values[2],
					database: values[3],
					inventory: values[4]
				};
			});
	},

	load: function() {
		return Promise.all([
			uci.load('apn-autoconfig'),
			this.loadDocuments()
		]);
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
			return _('This modem belongs to a network interface you created, so its configuration is left alone.');
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
		return !!(subject && subject.operation && !subject.operation.error && subject.operation.busy);
	},

	anySubjectBusy: function() {
		if (this.engineBusy)
			return true;
		return (this.subjects || []).some(function(subject) {
			return !!(subject.operation && !subject.operation.error && subject.operation.busy);
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
			{ name: 'sim', label: _('SIM & eSIM') },
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

		return E('div', { 'class': 'apn-workspace-header' }, [
			E('h3', {}, [ self.subjectHeading(subject) ]),
			E('div', { 'class': 'apn-strip' }, items)
		]);
	},

	areaNodes: function(subject) {
		switch (this.route.workspace) {
		case 'sim': return this.simAreaNodes(subject);
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

		/* Named gap 1: reordering mobile connections needs the modem package's
		 * connection-priority operation, and the read half that would list
		 * every interface competing for the default route. Until then this is
		 * a line and not a list. */
		nodes.push(E('h5', {}, [ _('Mobile route priority') ]));
		nodes.push(plannedLine('route-order',
			_('Planned: reordering mobile connections arrives with the modem package’s connection-priority operation.')));

		return nodes;
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

	/* ---- workspace: SIM & eSIM -------------------------------------------- */

	/* The hole the architecture deliberately leaves. The slot inventory has no
	 * publisher while the eSIM package is absent — named gap 2 — so this area
	 * carries the modem's active-SIM identity, says that the slots could not be
	 * determined, and renders the eUICC work as one planned line. It does not
	 * guess a slot count, and it does not draw a panel keyed by slot, which
	 * track C would have to undo. */
	simAreaNodes: function(subject) {
		var self = this;
		var status = subject.status;
		var nodes = [ E('h4', {}, [ _('SIM & eSIM') ]) ];

		if (!status || status.error) {
			nodes.push(unknownLine(_('The subscription in this modem'),
				_('The connection this modem is bound to could not be read just now.')));
			nodes.push(plannedLine('esim-read',
				_('Planned: eUICC profiles, and the operations on them, arrive with the eSIM package.')));
			return nodes;
		}

		nodes = nodes.concat(self.incompleteNotice(status));
		nodes.push(E('h5', {}, [ _('Active subscription') ]));
		nodes.push(table([
			row(_('Provider'), simProviderLabel(status)),
			row(_('Home network'), homeNetworkLabel(status),
				_('The network the SIM belongs to, which is what the APN profile is chosen for even while roaming on another one.')),
			row(_('SIM identifier'), sensitiveIdentifier(status.reconciled_iccid || status.iccid, _('SIM identifier'))),
			row(_('Backend slot index'), status.sim_index)
		]));

		nodes.push(E('h5', {}, [ _('Slots') ]));
		nodes.push(unknownLine(_('What each slot of this modem holds'),
			_('Nothing installed on this router publishes the slot inventory, so this is unread rather than empty. It is not a statement that there is one slot.')));
		nodes.push(plannedLine('esim-read',
			_('Planned: the slots this modem reports, the eUICC under the slot that has one, its subscriptions and their lifecycle arrive with the eSIM package.')));

		nodes.push(advanced([
			row(_('ICCID'), sensitiveIdentifier(status.iccid, _('ICCID'))),
			row(_('IMSI'), sensitiveIdentifier(status.imsi, _('IMSI'))),
			row(_('EID'), sensitiveIdentifier(status.eid, _('EID'))),
			row(_('Modem / control identifier'), status.modem_index)
		]));

		return nodes;
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
			if (plan.reason === 'already_provisioned' && plan.existing_section && plan.connection_owned === true)
				nodes.push(E('div', { 'class': 'apn-button-row' }, [
					self.bearerControl(subject, 'deprovision', _('Remove setup'), 'cbi-button-remove')
				]));
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
		var titles = {
			provision: _('Set up this modem'),
			deprovision: _('Remove setup'),
			connect: _('Connect'),
			disconnect: _('Disconnect'),
			reconnect: _('Reconnect')
		};
		var bodies = {
			provision: _('A new network interface called %s will be created for this modem. Its APN is chosen and verified before automatic connection is enabled. Nothing else on this router is changed.').format(plan.section || ''),
			deprovision: _('The network interface %s created for this modem will be stopped and removed. Interfaces you created yourself are never touched.').format(plan.existing_section || ''),
			connect: _('This asks netifd to bring the interface %s up. No configuration is changed.').format(section),
			disconnect: _('This stops the interface %s. Any connection through it will be interrupted. No configuration is changed.').format(section),
			reconnect: _('This stops and restarts the interface %s. Connectivity will be interrupted briefly. No configuration is changed.').format(section)
		};
		var extra = [];
		if (verb === 'provision' && plan.netifd_restart_required === true)
			extra.push(E('p', {}, [ _('The network service is restarted as part of this, so every interface on this router is interrupted briefly.') ]));
		if (verb === 'disconnect')
			extra.push(E('p', {}, [ _('This also records that you want it left down, so the program will not bring it back on its own.') ]));
		var destructive = verb === 'deprovision' || verb === 'disconnect';

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
	closeDialog: function() {
		var opener = this.dialogOpener;
		this.dialogContainer = null;
		this.dialogOpener = null;
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

		/* The profile travels in the environment, never in the arguments: a
		 * command line is readable by any local process through
		 * /proc/<pid>/cmdline, and an environment is not. */
		var env = { APN_AUTOCONFIG_MANUAL_APN: values.apn };
		if (values.username) {
			env.APN_AUTOCONFIG_MANUAL_USERNAME = values.username;
			env.APN_AUTOCONFIG_MANUAL_PASSWORD = values.password;
		}
		if (values.auth)
			env.APN_AUTOCONFIG_MANUAL_AUTH = values.auth;
		if (values.ip_type)
			env.APN_AUTOCONFIG_MANUAL_IP_TYPE = values.ip_type;

		self.engineBusy = true;
		self.setControlsBusy(true);

		function settle() {
			/* On success and on failure alike. */
			self.closeManualApn();
			values.password = '';
		}

		return call(controlCommand, [ 'apply-manual', subject.targetId ], env).then(function(result) {
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

		if (self.engineBusy)
			self.setControlsBusy(true);

		self.restoreFocus(focused);
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

	render: function(data) {
		var self = this;
		var documents = data[1];

		self.documents = documents;
		self.subjects = self.buildSubjects(documents);
		self.overviewExpanded = false;
		self.userEditing = false;
		self.controls = [];
		self.modemPollPending = false;
		self.actionPollPending = false;
		self.actionPollCount = 0;
		self.actionRendered = self.actionSignature(documents.action);
		self.hardwareIntegration = self.readHardwareIntegration(documents);

		var m = self.settingsMap();

		return m.render().then(function(mapNode) {
			self.overviewBox = E('div', { 'class': 'apn-overview' }, []);
			self.workspaceBox = E('div', { 'class': 'apn-workspace-host' }, []);
			self.databaseBox = E('div', { 'class': 'apn-database' }, []);

			var areas = [
				{ name: 'overview', label: _('Overview'), nodes: [ self.overviewBox, self.workspaceBox ] },
				{ name: 'database', label: _('Provider database'), nodes: [ self.databaseBox ] },
				/* The settings panel keeps its rendered form rather than being
				 * rebuilt on navigation: it holds values a user has typed, and
				 * nothing on this page may throw those away. */
				{ name: 'settings', label: _('Program settings'), nodes: [ mapNode ] }
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

			return self.page;
		});
	},

	readHardwareIntegration: function(documents) {
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
