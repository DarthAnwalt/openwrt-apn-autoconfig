'use strict';
'require view';
'require form';
'require fs';
'require uci';
'require ui';
'require poll';
'require dom';

var queryCommand = '/usr/libexec/apn-autoconfig-query';
var controlCommand = '/usr/libexec/apn-autoconfig-control';
var modemQueryCommand = '/usr/libexec/apn-autoconfig-modem-query';
var modemControlCommand = '/usr/libexec/apn-autoconfig-modem-control';

function call(command, args, env) {
	return fs.exec(command, args, env).then(function(result) {
		if (result.code !== 0)
			throw new Error((result.stderr || result.stdout || _('Command failed')).trim());

		try {
			return JSON.parse(result.stdout);
		}
		catch (e) {
			throw new Error(_('The APN helper returned invalid JSON'));
		}
	});
}

/* The provisioning verdict now travels with the inventory record itself.
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

function sensitiveIdentifier(value, label) {
	var identifier = value == null ? '' : String(value);
	if (!identifier)
		return text(value);

	var revealed = false;
	var display = E('span', {
		'class': 'apn-sensitive-value',
		'style': 'display:inline-block;width:%sch;font-family:monospace;white-space:nowrap'.format(identifier.length)
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
		'style': 'display:inline-flex;align-items:center;gap:.5em;white-space:nowrap'
	}, [ display, button ]);
}

/* Help opens on activation, never on hover: a hover tooltip is unreachable on
 * a touch screen, and touch screens are how many people administer a router.
 * The text is created when it is asked for rather than hidden with CSS, so
 * "not shown" and "not there" are the same state. */
function helpfulLabel(label, help) {
	if (!help)
		return E('strong', {}, [ label ]);

	var body = E('div', { 'class': 'apn-help-body' }, []);
	var opened = false;
	var button = E('button', {
		'class': 'btn cbi-button cbi-button-neutral apn-help-toggle',
		'type': 'button',
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

function signalQuality(value) {
	if (value == null || value === '')
		return '—';
	var percent = parseInt(value, 10);
	if (isNaN(percent))
		return text(value);
	percent = Math.max(0, Math.min(100, percent));
	return E('div', { 'class': 'cbi-progressbar', 'title': '%s%%'.format(percent) }, [
		E('div', { 'style': 'width:%s%%'.format(percent) })
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

function targetCapability(status, name) {
	/* A staggered upgrade from 0.9.0 has no target_capabilities yet and keeps
	 * the previously available ModemManager controls until status is refreshed
	 * from the new core. */
	return !status || !status.target_capabilities || status.target_capabilities[name] === true;
}

function roamingPolicySupported(status) {
	if (!status || status.error || status.version !== 'v2')
		return false;
	/* Capability is reported explicitly. A backend name is not a substitute:
	 * an engine that predates roaming_policy_write still describes exactly the
	 * one backend that had it. */
	if (status.target_capabilities && 'roaming_policy_write' in status.target_capabilities)
		return status.target_capabilities.roaming_policy_write === true;
	return status.target_backend === 'modemmanager' && targetCapability(status, 'profile_write');
}

function roamingPolicyDescription(status) {
	var target = status && status.interface || 'wwan';
	var backend = status && status.target_backend || _('unknown');
	if (!roamingPolicySupported(status))
		return _('Roaming policy control is unavailable for the selected %s backend. APN Auto-Config manages only APN profiles; configure roaming in the package or interface that manages this connection.').format(backend);
	if (backend === 'mbim')
		return _('This edits the canonical network.%s.allow_roaming and allow_partner options used by netifd. Both are needed: OpenWrt refuses roaming and partner networks when they are unset, and APN profiles never change them automatically.').format(target);
	return _('This edits the canonical network.%s.allow_roaming option used by netifd and ModemManager. APN profiles never change it automatically.').format(target);
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

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('apn-autoconfig'),
			call(queryCommand, [ 'status' ]).catch(function(error) { return { error: error.message }; }),
			call(queryCommand, [ 'action-status' ]).catch(function(error) { return { error: error.message }; }),
			call(queryCommand, [ 'database-status' ]).catch(function(error) { return { error: error.message }; }),
			call(queryCommand, [ 'targets' ]).catch(function(error) { return { error: error.message }; }),
			call(modemQueryCommand, [ 'inventory' ]).catch(function(error) { return { error: error.message }; })
				.then(function(inventory) {
					var modems = inventory && Array.isArray(inventory.modems) ? inventory.modems : [];
					if (!modems.length)
						return inventory;
					/* The plan arrives with the record. Only the operation
					 * state still needs a call of its own, because it is a
					 * coordinator fact rather than an inventory one. */
					return Promise.all(modems.map(function(modem) {
						modem.plan = planOf(modem);
						return call(modemQueryCommand, [ 'action-status', modem.modem_id ])
							.catch(function(error) { return { error: error.message }; })
							.then(function(operation) {
								modem.operation = operation;
								return modem;
							});
					})).then(function() { return inventory; });
				})
		]);
	},

	/* ---- status strip -------------------------------------------------- */

	/* Tabs hide state, and the state most worth seeing is exactly the state a
	 * user is least likely to be looking at when it breaks. Everything here is
	 * visible from every tab. */
	stripNodes: function(status, action) {
		var items = [];

		function item(label, value, cssClass) {
			return E('div', { 'class': 'apn-strip-item ' + (cssClass || '') }, [
				E('span', { 'class': 'apn-strip-label' }, [ label ]),
				E('span', { 'class': 'apn-strip-value' }, [ valueNode(value) ])
			]);
		}

		if (!status || status.error) {
			items.push(item(_('Target'), _('unavailable'), 'apn-strip-bad'));
			items.push(item(_('Status'), status && status.error || _('unknown error'), 'apn-strip-bad'));
			return [ E('div', { 'class': 'apn-strip' }, items) ];
		}

		items.push(item(_('Target'), '%s (%s)'.format(status.interface, status.target_backend || _('unknown'))));
		items.push(item(_('Registration'), registrationLabel(status),
			status.registration_state === 'denied' || status.registration_state === 'emergency-only'
				? 'apn-strip-bad' : ''));
		items.push(item(_('Connection'), status.interface_up ? _('up') : _('down or pending'),
			status.interface_up ? 'apn-strip-good' : 'apn-strip-warn'));

		var failed = status.result_code && status.result_code !== 'success';
		items.push(item(_('Last result'), status.last_result || _('nothing recorded yet'),
			failed ? 'apn-strip-bad' : ''));

		var running = action && !action.error && action.busy;
		if (running)
			items.push(item(_('Running'), this.actionDescription(action), 'apn-strip-busy'));

		return [ E('div', { 'class': 'apn-strip' }, items) ];
	},

	refreshStrip: function() {
		if (this.stripBox)
			dom.content(this.stripBox, this.stripNodes(this.currentStatus, this.currentAction));
	},

	/* ---- modem area ---------------------------------------------------- */

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

	/* The modem's own name for itself, read over AT. It is display evidence, not
	 * identity — two identical modems say exactly the same thing — so it never
	 * replaces the identifier under the advanced disclosure. Falls back to the
	 * USB ids, which are all that is known before an identity read has run. */
	modemModelLabel: function(modem) {
		if (modem.manufacturer && modem.model)
			return '%s %s'.format(modem.manufacturer, modem.model);
		if (modem.model)
			return modem.model;
		if (modem.vendor_id && modem.product_id)
			return _('Unidentified (%s:%s)').format(modem.vendor_id, modem.product_id);
		return _('Unidentified');
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

	/* Why a modem cannot be set up, in the user's terms. A missing control is
	 * always explained; the view never shows a button that is going to fail. */
	provisionReasonText: function(reason, modem) {
		switch (reason) {
		case 'already_configured':
			return _('This modem belongs to a network interface you created, so its configuration is left alone. It can still be connected and disconnected from here.');
		case 'already_provisioned':
			return _('This modem is set up by this package.');
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

	modemOperationText: function(operation) {
		if (!operation || operation.error)
			return '';
		if (operation.busy)
			return _('Working on this modem…');
		switch (operation.state) {
		case 'success': return _('Last operation finished successfully.');
		case 'failed': return _('Last operation failed: %s').format(operation.message || _('unknown error'));
		case 'blocked': return _('Last operation was refused: %s').format(operation.message || _('not permitted'));
		case 'retryable': return _('Last operation could not finish and may be retried: %s').format(operation.message || '');
		}
		return '';
	},

	modemActionButton: function(modem, verb, label, cssClass) {
		var self = this;
		var button = E('button', {
			'class': 'btn cbi-button ' + cssClass,
			'type': 'button',
			'click': function(ev) { ev.preventDefault(); self.confirmModemAction(modem, verb); }
		}, [ label ]);
		/* Either lock is enough to make this fail. The modem's own operation is
		 * the obvious one; a busy engine — a reconcile, a power-cycle, an SSH
		 * command or the physical button — holds the same global lock, and a
		 * card re-rendered while that runs must come back disabled too. */
		button.disabled = !!(modem.operation && modem.operation.busy) || !!self.busy;
		self.modemButtons.push(button);
		return button;
	},

	/* One card per modem, answering "what is the hardware doing?". The old page
	 * answered it twice, in two cards far enough apart that they never appeared
	 * together and nobody could say what separated them. */
	modemAreaNodes: function(inventory, status) {
		var self = this;
		self.modemButtons = [];
		self.resetButtons = [];
		self.resetButton = null;

		var cards;
		if (!inventory || inventory.error)
			cards = [ E('p', { 'class': 'apn-modem-unavailable' }, [
				_('Modem inventory is unavailable. The optional apn-autoconfig-modem package may be absent, disabled or unable to complete its bounded scan. The APN functions remain independent of it.')
			]) ];
		else {
			var modems = Array.isArray(inventory.modems) ? inventory.modems : [];
			if (!modems.length)
				cards = [ E('p', {}, [ _('No modem was detected by the current read-only scan.') ]) ];
			else
				cards = modems.map(function(modem) {
					return self.modemCard(modem, self.radioBelongsTo(modem, status) ? status : null);
				});
		}

		/* The radio block belongs to whichever modem is the APN target. If that
		 * modem is not in the inventory — the package may be absent, or the
		 * target may be an interface no scanned modem claims — it is shown on
		 * its own rather than dropped, because it is still true. */
		var orphan = [];
		if (status && !status.error) {
			var claimed = (inventory && Array.isArray(inventory.modems) ? inventory.modems : [])
				.some(function(modem) { return self.radioBelongsTo(modem, status); });
			if (!claimed)
				orphan.push(E('div', { 'class': 'apn-modem-entry' }, [
					E('h4', {}, [ _('Mobile connection') ]),
					self.radioTable(status)
				]));
		}

		return orphan.concat(cards);
	},

	/* Which modem the radio and SIM readings describe.
	 *
	 * They used to be rendered once, above every card. With one modem that read
	 * as a page header; with two it silently attributed one modem's signal,
	 * network and registration to both, and nothing on the page said which one
	 * it meant. The APN status names its interface, and a modem names the
	 * interface bound to it, so the two can simply be matched. */
	radioBelongsTo: function(modem, status) {
		if (!modem || !status || status.error || !status.interface)
			return false;
		var plan = modem.plan || {};
		return status.interface === modem.netifd_interface ||
			status.interface === plan.connection_section;
	},

	radioTable: function(status) {
		return table([
			row(_('Serving network'), networkLabel(status.serving_operator_name, status.serving_operator_id),
				_('The network currently carrying the radio link. While roaming this differs from the provider your APN profile was matched from.')),
			row(_('Registration'), registrationLabel(status),
				_('Whether the modem is registered on a network. APN profiles are never tested before registration succeeds.')),
			row(_('Access technologies'), (status.access_technologies || '').replace(/,/g, ' + ')),
			row(_('Signal quality'), signalQuality(status.signal_quality)),
			row(_('Mobile interface'), '%s: %s'.format(status.interface,
				status.interface_up ? _('up') : _('down or pending')))
		]);
	},

	/* A name for one modem, so a page showing two of them says which is which.
	 * The model is what a person recognises; the interface is what distinguishes
	 * two of the same model. Neither is an identifier that needs masking. */
	modemHeading: function(modem) {
		var plan = modem.plan || {};
		var name = this.modemModelLabel(modem);
		var iface = modem.netifd_interface || plan.connection_section;
		return iface ? '%s — %s'.format(name, iface) : name;
	},

	modemCard: function(modem, status) {
		var self = this;
		var plan = modem.plan || {};
		var buttons = [];
		var explanation = '';

		var rows = [
			row(_('Model'), self.modemModelLabel(modem)),
			row(_('Protocol'), modem.protocol),
			row(_('Control owner'), self.modemOwnerStateLabel(modem.owner_state),
				_('Which component is allowed to talk to this modem. Two components claiming it at once stops every operation rather than racing them.')),
			row(_('Network interface'), modem.netifd_interface || plan.connection_section || _('none'))
		];
		if (modem.ambiguous)
			rows.push(row(_('Ambiguous'), modem.ambiguity_reason || _('yes')));

		if (plan.error)
			explanation = _('The setup check could not run. See the system log for details.');
		else {
			/* Bearer control and configuration control are separate questions,
			 * and the backend answers the first one for us: connect is offered
			 * exactly when the runtime would accept it. */
			if (plan.can_control_bearer) {
				buttons.push(self.modemActionButton(modem, 'connect', _('Connect'), 'cbi-button-action'));
				buttons.push(self.modemActionButton(modem, 'reconnect', _('Reconnect'), 'cbi-button-neutral'));
				buttons.push(self.modemActionButton(modem, 'disconnect', _('Disconnect'), 'cbi-button-neutral'));
			}
			if (plan.can_provision) {
				rows.push(row(_('Would create interface'), text(plan.section)));
				explanation = _('This modem is not configured yet. Setting it up creates a new network interface, finds the right APN for its SIM, verifies real Internet access and only then enables automatic connection. If anything fails, everything is undone.');
				buttons.push(self.modemActionButton(modem, 'provision', _('Set up this modem'), 'cbi-button-action important'));
			}
			else {
				explanation = self.provisionReasonText(plan.reason, modem);
				if (plan.reason === 'already_provisioned')
					buttons.push(self.modemActionButton(modem, 'deprovision', _('Remove setup'), 'cbi-button-remove'));
			}
		}

		/* Reset stopped being a board-integration feature: the backend picks a
		 * method from whoever owns the modem, so the control is offered
		 * whenever it says one applies. Gating on the board package as well
		 * would hide a working reset on every modem the board GPIO cannot
		 * reach — which is exactly the case the new methods exist for. */
		if (modem.capabilities && modem.capabilities.reset === true)
			buttons.push(self.resetButtonFor(modem));

		var nodes = [ E('h4', { 'class': 'apn-modem-title' }, [ self.modemHeading(modem) ]),
			table(rows), E('p', {}, [ explanation ]) ];
		/* The SIM and radio readings for this modem, under this modem. The
		 * heading is deliberately "SIM and radio" rather than "radio": the eSIM
		 * release adds a profile list beneath it, and it should arrive inside a
		 * section that already exists rather than by rearranging this one. */
		if (status)
			nodes.push(E('div', { 'class': 'apn-modem-radio' }, [
				E('h5', {}, [ _('SIM and radio') ]),
				self.radioTable(status)
			]));
		var operationText = self.modemOperationText(modem.operation);
		if (operationText)
			nodes.push(E('p', { 'class': 'apn-action-status' }, [ operationText ]));
		if (buttons.length)
			nodes.push(E('div', { 'class': 'apn-button-row' }, buttons));

		nodes.push(advanced([
			row(_('Modem identity'), sensitiveIdentifier(modem.modem_id, _('modem identity'))),
			row(_('Evidence'), modem.evidence_tier),
			row(_('Firmware'), modem.firmware_revision),
			row(_('Reset method'), self.modemResetMethodLabel(modem.reset_method),
				_('How this modem would be reset. Board power is used wherever the hardware supports it; otherwise the component that owns the modem is asked to reset it, or a reset command is sent over the modem\'s own control port.')),
			row(_('Implementation'), modem.implementation_state),
			row(_('Validation'), modem.hardware_validated ? _('hardware') : modem.validation_state),
			row(_('USB path'), modem.usb_path),
			row(_('AT control port'), modem.at_device),
			row(_('Vendor / product'), modem.vendor_id && modem.product_id
				? '%s:%s'.format(modem.vendor_id, modem.product_id) : ''),
			row(_('Control device'), modem.control_device),
			row(_('Data device'), modem.data_device),
			row(_('First seen'), formatTimestamp(modem.first_seen))
		]));

		return E('div', { 'class': 'apn-modem-entry' }, nodes);
	},

	/* The power-cycle keeps running through the engine command the hardware
	 * button already uses, so the validated reset-then-reconcile behaviour is
	 * unchanged; only where the control lives has moved. */
	resetButtonFor: function(modem) {
		var self = this;
		/* The label names what will actually happen, because the three methods
		 * are not interchangeable to a user watching the device: cutting board
		 * power and asking the modem to restart itself look different and take
		 * different amounts of time. */
		var label = _('Restart modem');
		if (modem && modem.reset_method === 'gpio')
			label = _('Power-cycle modem');
		var button = E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'type': 'button',
			'click': function(ev) { ev.preventDefault(); self.confirmAction('modem-reset'); }
		}, [ label ]);
		button.disabled = !!self.busy;
		/* Tracked as a list because a board could pin more than one modem, and
		 * disabling only the most recently rendered one would leave a live
		 * control behind during an operation. */
		self.resetButtons.push(button);
		self.resetButton = self.resetButtons[0];
		self.modemButtons.push(button);
		return button;
	},

	confirmModemAction: function(modem, verb) {
		var self = this;
		if (modem.operation && modem.operation.busy)
			return;

		var plan = modem.plan || {};
		var section = plan.connection_section || plan.existing_section || modem.netifd_interface || '';
		var titles = {
			provision: _('Set up this modem'),
			deprovision: _('Remove setup'),
			connect: _('Connect'),
			disconnect: _('Disconnect'),
			reconnect: _('Reconnect')
		};
		/* Every bearer-control confirmation names the interface it will act on,
		 * because offering to start an interface is not a claim to own it and
		 * the user has to be able to tell which one this is. */
		var warnings = {
			provision: _('A new network interface called %s will be created for this modem. Its APN is chosen and verified before automatic connection is enabled. Nothing else on this router is changed.').format(plan.section || ''),
			deprovision: _('The network interface %s created for this modem will be stopped and removed. Interfaces you created yourself are never touched.').format(plan.existing_section || ''),
			connect: _('This asks netifd to bring the interface %s up. No configuration is changed.').format(section),
			disconnect: _('This stops the interface %s. Any connection through it will be interrupted. No configuration is changed.').format(section),
			reconnect: _('This stops and restarts the interface %s. Connectivity will be interrupted briefly. No configuration is changed.').format(section)
		};
		var destructive = verb === 'deprovision' || verb === 'disconnect';

		ui.showModal(titles[verb], [
			E('p', {}, [ warnings[verb] ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
				' ',
				E('button', {
					'class': 'btn important ' + (destructive ? 'cbi-button-remove' : 'cbi-button-action'),
					'click': function() {
						ui.hideModal();
						self.startModemAction(modem, verb);
					}
				}, [ titles[verb] ])
			])
		]);
	},

	startModemAction: function(modem, verb) {
		var self = this;
		self.setModemButtonsBusy(true);

		return call(modemControlCommand, [ verb, modem.modem_id ]).then(function(result) {
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

	setModemButtonsBusy: function(busy) {
		(this.modemButtons || []).forEach(function(button) { button.disabled = !!busy; });
	},

	refreshProvisioning: function() {
		var self = this;
		return call(modemQueryCommand, [ 'inventory' ]).then(function(inventory) {
			var modems = Array.isArray(inventory.modems) ? inventory.modems : [];
			return Promise.all(modems.map(function(modem) {
				modem.plan = planOf(modem);
				return call(modemQueryCommand, [ 'action-status', modem.modem_id ])
					.catch(function(error) { return { error: error.message }; })
					.then(function(operation) { modem.operation = operation; });
			})).then(function() { return inventory; });
		}).then(function(inventory) {
			self.modemInventory = inventory;
			var anyBusy = (Array.isArray(inventory.modems) ? inventory.modems : []).some(function(modem) {
				return modem.operation && modem.operation.busy;
			});
			self.modemPollPending = anyBusy;
			if (self.modemBox)
				dom.content(self.modemBox, self.modemAreaNodes(inventory, self.currentStatus));
		}).catch(function() {
			/* A lost poll never invents a result; the next tick tries again. */
		});
	},

	/* ---- APN area ------------------------------------------------------ */

	apnAreaNodes: function(status) {
		var self = this;
		/* An unavailable status is where the guidance about other discovered
		 * targets belongs: it is the one place that can say what to select
		 * instead, and it must not be lost behind an "unavailable" line. */
		if (!status || status.error)
			return this.statusWarnings(status);

		var nodes = this.statusWarnings(status);
		nodes.push(table([
			row(_('Matched provider'), simProviderLabel(status),
				_('The database record this APN profile was selected from. While roaming it differs from the network currently carrying the link, which is shown under Modem.')),
			row(_('Configured APN'), status.configured_apn || _('<empty>')),
			row(_('Cached APN for this SIM'), status.cached_apn,
				_('The profile last verified for this SIM. It is reused instead of searching the database again.')),
			row(_('Reconciled APN'), status.reconciled_apn),
			row(_('Last result'), status.last_result)
		]));

		nodes.push(E('div', { 'class': 'apn-button-row' }, [ self.reconcileButton, self.manualButton ]));

		nodes.push(E('h4', {}, [ _('Roaming data policy') ]));
		nodes.push(self.policyDescription);
		nodes.push(E('div', { 'class': 'apn-policy-controls' }, [ self.policySelect, self.policyButton ]));

		nodes.push(advanced([
			row(_('Engine target'), status.target_id),
			row(_('Protocol / backend'), '%s / %s'.format(status.target_protocol, status.target_backend)),
			row(_('Implementation / validation'), '%s / %s'.format(
				status.target_implementation_state || '—', status.target_validation_state || '—')),
			row(_('Hardware validated'), status.target_hardware_validated ? _('yes') : _('no')),
			row(_('Effective data device'), status.l3_device || status.device),
			row(_('Manual operator lock (PLMN)'), status.configured_plmn),
			row(_('Database format'), status.database_format ? 'v%s'.format(status.database_format) : ''),
			row(_('Sources'), status.database_sources),
			row(_('Source revisions'), status.database_revisions),
			row(_('Database path'), status.database_path)
		]));

		return nodes;
	},

	statusWarnings: function(status) {
		var nodes = [];
		if (!status || status.error) {
			var alternatives = this.targetInventory && Array.isArray(this.targetInventory.targets)
				? this.targetInventory.targets.filter(function(target) {
					return target.capabilities && target.capabilities.identity === true &&
						target.id !== (this.targetInventory.configured_target || '');
				}, this).map(function(target) {
					return '%s (%s)'.format(target.interface, target.protocol);
				}) : [];
			var messages = [
				_('Status is temporarily unavailable: %s').format(status && status.error || _('unknown error'))
			];
			if (alternatives.length)
				messages.push(_('Other cellular targets were discovered: %s. To inspect or control one of them, select it under Settings → Mobile target and save. APN Auto-Config will not switch targets silently.').format(alternatives.join(', ')));
			return [ E('div', { 'class': 'alert-message warning' }, messages.map(function(message) {
				return E('p', {}, [ message ]);
			})) ];
		}

		if (status.roaming === true)
			nodes.push(E('div', { 'class': status.roaming_allowed ? 'alert-message notice' : 'alert-message warning' }, [
				status.roaming_allowed
					? _('Roaming via %s. Mobile data is %s.').format(
						networkLabel(status.serving_operator_name, status.serving_operator_id), roamingPolicyLabel(status).toLowerCase())
					: _('Roaming via %s, but mobile data roaming is explicitly blocked. APN profiles will not be tested.').format(
						networkLabel(status.serving_operator_name, status.serving_operator_id))
			]));
		else if (status.registration_state === 'denied' || status.registration_state === 'emergency-only')
			nodes.push(E('div', { 'class': 'alert-message warning' }, [
				_('Mobile registration is %s. This happens before APN testing.').format(status.registration_state)
			]));
		return nodes;
	},

	/* ---- SIM area ------------------------------------------------------ */

	simAreaNodes: function(status) {
		if (!status || status.error)
			return [ E('p', { 'class': 'alert-message warning' }, [
				_('SIM status is unavailable: %s').format(status && status.error || _('unknown error'))
			]) ];

		return [
			table([
				row(_('SIM / eSIM provider'), simProviderLabel(status)),
				row(_('Home network'), homeNetworkLabel(status),
					_('The network the SIM belongs to, which is what the APN profile is chosen for even while roaming on another one.')),
				row(_('Reconciled SIM'), sensitiveIdentifier(status.reconciled_iccid, _('SIM identifier'))),
				row(_('SIM slot / backend index'), status.sim_index)
			]),
			E('p', {}, [
				_('eSIM profile management is not part of this release. This area holds the subscription identity the APN engine reads today.')
			]),
			advanced([
				row(_('ICCID'), sensitiveIdentifier(status.iccid, _('ICCID'))),
				row(_('IMSI'), sensitiveIdentifier(status.imsi, _('IMSI'))),
				row(_('EID'), sensitiveIdentifier(status.eid, _('EID'))),
				row(_('Modem / control identifier'), status.modem_index)
			])
		];
	},

	/* ---- provider database --------------------------------------------- */

	databaseAlert: function(database) {
		if (!database || database.error)
			return E('div', { 'class': 'alert-message warning' }, [
				_('Database update status is unavailable: %s').format(database && database.error || _('unknown error'))
			]);
		var warning = database.state === 'check-failed' || database.state === 'install-failed' ||
			!database.feed_configured || !database.key_trusted;
		return E('div', { 'class': warning ? 'alert-message warning' : 'alert-message notice' }, [
			text(database.message)
		]);
	},

	databaseNodes: function(database) {
		if (!database || database.error)
			return [ this.databaseAlert(database) ];
		var rows = [
			row(_('Installed package version'), database.installed_package_version),
			row(_('Database version'), database.database_version),
			row(_('Data release date'), databaseReleaseDate(database.database_version)),
			row(_('Last update check'), formatTimestamp(database.checked_at) || _('Not checked yet')),
			row(_('Last installation through this page'), formatTimestamp(database.installed_at) || _('Not recorded'))
		];
		if (database.update_available)
			rows.splice(3, 0, row(_('Available package version'), database.available_package_version));

		return [
			this.databaseAlert(database),
			table(rows),
			E('div', { 'class': 'apn-button-row' }, [
				this.databaseCheckButton,
				this.databaseInstallButton
			]),
			advanced([
				row(_('Signed package feed'), trustLabel(database.feed_configured, _('Configured'), _('Not configured'))),
				row(_('Repository signing key'), trustLabel(database.key_trusted, _('Trusted'), _('Not installed'))),
				row(_('Feed URL'), database.feed_url)
			])
		];
	},

	/* ---- operations ----------------------------------------------------- */

	actionLabel: function(action) {
		switch (action) {
		case 'reconcile': return _('APN re-detection');
		case 'modem-reset': return _('modem power-cycle');
		case 'apply-manual': return _('manual APN');
		case 'roaming-default':
		case 'roaming-allow':
		case 'roaming-block': return _('roaming policy change');
		case 'database-check': return _('database update check');
		case 'database-install': return _('database installation');
		default: return action || _('operation');
		}
	},

	actionDescription: function(action) {
		if (!action || action.error)
			return action && action.error || _('Operation status is unavailable');
		var label = this.actionLabel(action.action);
		switch (action.state) {
		case 'starting':
		case 'queued': return _('The %s is queued.').format(label);
		case 'running': return _('The %s is running. Please wait; this may take over a minute.').format(label);
		case 'external': return _('An APN, modem or database operation started outside LuCI is running.');
		case 'success': return _('The last %s completed successfully.').format(label);
		case 'failed': return _('The last %s failed: %s').format(label, action.message || _('see system log'));
		case 'blocked': return _('The %s was intentionally blocked by the roaming policy.').format(label);
		case 'retryable': return _('The %s could not run because another operation or a temporary mobile state prevents it. It is safe to retry.').format(label);
		default: return _('No operation is running.');
		}
	},

	setBusy: function(busy, action) {
		this.busy = !!busy;
		this.currentAction = action;
		if (this.manualButton)
			this.manualButton.disabled = this.busy || !this.profileApplySupported;
		if (this.reconcileButton)
			this.reconcileButton.disabled = this.busy || !this.profileApplySupported;
		(this.resetButtons || []).forEach(function(button) {
			button.disabled = this.busy || !this.profileApplySupported;
		}, this);
		/* The modem card's controls are otherwise only refreshed when LuCI
		 * itself started a modem action, so an operation from any other entry
		 * point left them clickable and they failed on the lock instead. */
		if (this.busy)
			this.setModemButtonsBusy(true);
		this.updatePolicyControls();
		this.updateDatabaseControls();
		this.refreshStrip();
	},

	/* The three policies cannot express a custom option pair, so that state is
	 * shown as its own disabled entry: applying then requires deliberately
	 * choosing one, instead of an Apply click silently normalizing it. */
	setPolicyOptions: function(status) {
		if (this.policyDefaultOption)
			dom.content(this.policyDefaultOption, [ defaultPolicyOptionLabel(status) ]);
		if (this.policyCustomOption)
			this.policyCustomOption.hidden = !roamingPolicyCustom(status);
		if (this.policySelect)
			this.policySelect.value = policyValue(status);
	},

	updatePolicyControls: function() {
		if (this.policyButton)
			this.policyButton.disabled = this.busy || !this.policySupported || !this.policyDirty;
		if (this.policySelect)
			this.policySelect.disabled = this.busy || !this.policySupported;
	},

	updateDatabaseControls: function() {
		var available = !!(this.databaseStatus && this.databaseStatus.update_available);
		if (this.databaseCheckButton)
			this.databaseCheckButton.disabled = this.busy;
		if (this.databaseInstallButton) {
			this.databaseInstallButton.disabled = this.busy || !available;
			this.databaseInstallButton.style.display = available ? '' : 'none';
		}
	},

	setDatabaseStatus: function(database) {
		this.databaseStatus = database;
		if (this.databaseBox)
			dom.content(this.databaseBox, this.databaseNodes(database));
		this.updateDatabaseControls();
	},

	refreshDatabase: function() {
		var self = this;
		return call(queryCommand, [ 'database-status' ]).catch(function(error) {
			return { error: error.message };
		}).then(function(database) {
			self.setDatabaseStatus(database);
		});
	},

	refreshPanels: function() {
		var self = this;
		return Promise.all([
			call(queryCommand, [ 'status' ]).catch(function(error) { return { error: error.message }; }),
			call(queryCommand, [ 'database-status' ]).catch(function(error) { return { error: error.message }; })
		]).then(function(values) {
			var status = values[0];
			self.currentStatus = status;
			self.profileApplySupported = status && !status.error && targetCapability(status, 'profile_apply');
			self.policySupported = roamingPolicySupported(status);
			if (self.policySelect && self.policySupported) {
				self.setPolicyOptions(status);
				self.policyDirty = false;
			}
			if (self.policyDescription)
				dom.content(self.policyDescription, [ roamingPolicyDescription(status) ]);
			if (self.apnBox)
				dom.content(self.apnBox, self.apnAreaNodes(status));
			if (self.simBox)
				dom.content(self.simBox, self.simAreaNodes(status));
			if (self.modemBox)
				dom.content(self.modemBox, self.modemAreaNodes(self.modemInventory, status));
			self.setDatabaseStatus(values[1]);
			self.updatePolicyControls();
			self.refreshStrip();
		});
	},

	refreshStatus: function() {
		var self = this;
		return call(queryCommand, [ 'action-status' ]).then(function(action) {
			var wasBusy = self.busy;
			var databaseAction = action.action === 'database-check' || action.action === 'database-install';
			self.setBusy(action.busy, action);

			if (wasBusy && !action.busy) {
				self.panelPollCount = 0;
				self.panelRetryPending = false;
				return self.refreshPanels().then(function() { self.setBusy(false, action); });
			}
			if (action.busy && databaseAction)
				return self.refreshDatabase().then(function() { self.setBusy(true, action); });
			if (!action.busy && self.panelRetryPending) {
				self.panelPollCount++;
				if (self.panelPollCount >= 5) {
					self.panelPollCount = 0;
					self.panelRetryPending = false;
					return self.refreshPanels().then(function() { self.setBusy(false, action); });
				}
			}
		}).catch(function(error) {
			/* A transient polling failure is not evidence that a long-running
			 * operation ended. Keep controls disabled until the core says so. */
			self.setBusy(self.busy, { error: error.message });
		});
	},

	confirmRoamingPolicy: function() {
		var self = this;
		if (self.busy || !self.policySupported || !self.policyDirty)
			return;

		var value = self.policySelect.value;
		var labels = {
			'default': _('Use the OpenWrt default (allowed)'),
			'allow': _('Explicitly allow roaming data'),
			'block': _('Explicitly block roaming data')
		};
		ui.showModal(_('Change roaming data policy'), [
			E('p', {}, [ _('Apply “%s” to the mobile interface? If needed, the mobile connection will be stopped or re-established.').format(labels[value]) ]),
			E('p', {}, [ _('Allowing roaming data does not mean that roaming is included in your tariff or free of charge.') ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
				' ',
				E('button', {
					'class': 'btn cbi-button-action important',
					'click': function() {
						ui.hideModal();
						self.startAction('roaming-' + value);
					}
				}, [ _('Apply policy') ])
			])
		]);
	},

	startAction: function(action) {
		var self = this;
		self.setBusy(true, { state: 'starting', action: action });

		return call(controlCommand, [ action ]).then(function(result) {
			self.setBusy(result.busy, result);
			if (!result.accepted && !result.busy)
				throw new Error(result.message || _('The operation could not be started'));
			if (result.accepted && !result.busy)
				return self.refreshPanels().then(function() { self.setBusy(false, result); });
		}).catch(function(error) {
			/* The launch response may have been lost after the job was accepted.
			 * Polling will safely determine when controls may be re-enabled. */
			self.setBusy(true, { error: error.message });
			ui.addNotification(null, E('p', {}, [ error.message ]), 'error');
		});
	},

	confirmAction: function(action) {
		var self = this;
		if (self.busy || !self.profileApplySupported)
			return;
		var reset = action === 'modem-reset';
		ui.showModal(reset ? _('Power-cycle modem') : _('Re-detect APN'), [
			E('p', {}, [ reset
				? _('This stops only the mobile interface, power-cycles the modem, waits for the SIM and then verifies or corrects the APN. Mobile connectivity will be interrupted temporarily.')
				: _('This verifies the current SIM, APN and real Internet access. If necessary, it changes the APN and restarts only the mobile interface.')
			]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
				' ',
				E('button', {
					'class': 'btn cbi-button-action important',
					'click': function() {
						ui.hideModal();
						self.startAction(action);
					}
				}, [ reset ? _('Power-cycle modem') : _('Re-detect APN') ])
			])
		]);
	},

	confirmDatabaseInstall: function() {
		var self = this;
		if (self.busy || !self.databaseStatus || !self.databaseStatus.update_available)
			return;
		ui.showModal(_('Install provider database update'), [
			E('p', {}, [ _('Install signed provider database package %s?').format(self.databaseStatus.available_package_version) ]),
			E('p', {}, [ _('Only the provider database package will be updated. The active APN and mobile connection will not be changed.') ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
				' ',
				E('button', {
					'class': 'btn cbi-button-positive important',
					'click': function() {
						ui.hideModal();
						self.startAction('database-install');
					}
				}, [ _('Install update') ])
			])
		]);
	},

	/* ---- manual APN entry ----------------------------------------------- */

	/* Manual entry is the fallback for a SIM the database does not cover.
	 * Presented as a permanently expanded form it asked every user to fill in
	 * something almost nobody should need, on a page whose normal answer is
	 * "the automatic path already worked". */
	openManualApn: function() {
		var self = this;
		if (self.busy || !self.profileApplySupported)
			return;

		self.manualApn = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': _('internet.example') });
		self.manualUsername = E('input', { 'type': 'text', 'class': 'cbi-input-text' });
		self.manualPassword = E('input', { 'type': 'password', 'class': 'cbi-input-password' });
		self.manualAuth = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': '' }, [ _('Not specified') ]),
			E('option', { 'value': 'none' }, [ _('None') ]),
			E('option', { 'value': 'pap' }, [ 'PAP' ]),
			E('option', { 'value': 'chap' }, [ 'CHAP' ]),
			E('option', { 'value': 'pap-or-chap' }, [ _('PAP or CHAP') ])
		]);
		self.manualIpType = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': '' }, [ _('Not specified') ]),
			E('option', { 'value': 'ipv4' }, [ 'IPv4' ]),
			E('option', { 'value': 'ipv6' }, [ 'IPv6' ]),
			E('option', { 'value': 'ipv4v6' }, [ _('IPv4 and IPv6') ])
		]);

		ui.showModal(_('Enter an APN yourself'), [
			E('p', {}, [
				_('Use this when the database has no profile for your SIM, or your operator issued you a private one. The profile is tested like any other: the current one is saved first, real Internet access is verified, and a profile that does not work is undone.')
			]),
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
					'click': function() {
						/* Cancelling writes nothing and keeps nothing: the
						 * password field must not survive the dialog. */
						self.manualPassword = null;
						ui.hideModal();
					}
				}, [ _('Cancel') ]),
				' ',
				E('button', {
					'class': 'btn cbi-button-action important',
					'click': function() { self.confirmManualApn(); }
				}, [ _('Apply this APN') ])
			])
		]);
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
		if (self.busy)
			return;

		var values = self.manualApnValues();
		var error = self.manualApnError(values);
		if (error) {
			/* Refused before any wrapper call: the dialog stays open so the
			 * entry can be corrected. */
			ui.addNotification(null, E('p', {}, [ error ]), 'warning');
			return;
		}

		ui.showModal(_('Apply this APN'), [
			E('p', {}, [ _('The APN %s will be applied to the mobile interface and tested. Mobile connectivity will be interrupted briefly.').format(values.apn) ]),
			E('p', {}, [ _('If it does not provide real Internet access, the previous profile is restored automatically.') ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
				' ',
				E('button', {
					'class': 'btn cbi-button-action important',
					'click': function() {
						ui.hideModal();
						self.startManualApn(values);
					}
				}, [ _('Apply this APN') ])
			])
		]);
	},

	startManualApn: function(values) {
		var self = this;
		var target = self.currentStatus && self.currentStatus.target_id || '';
		if (!target) {
			ui.addNotification(null, E('p', {}, [ _('No mobile target is selected.') ]), 'error');
			return;
		}

		/* The profile travels in the environment, never in the arguments: a
		 * command line is readable by any local process, an environment is
		 * not. */
		var env = { APN_AUTOCONFIG_MANUAL_APN: values.apn };
		if (values.username) {
			env.APN_AUTOCONFIG_MANUAL_USERNAME = values.username;
			env.APN_AUTOCONFIG_MANUAL_PASSWORD = values.password;
		}
		if (values.auth)
			env.APN_AUTOCONFIG_MANUAL_AUTH = values.auth;
		if (values.ip_type)
			env.APN_AUTOCONFIG_MANUAL_IP_TYPE = values.ip_type;

		self.setBusy(true, { state: 'starting', action: 'apply-manual' });

		return call(controlCommand, [ 'apply-manual', target ], env).then(function(result) {
			if (self.manualPassword)
				self.manualPassword.value = '';
			self.setBusy(result.busy, result);
			if (!result.accepted && !result.busy)
				throw new Error(result.message || _('The operation could not be started'));
		}).catch(function(error) {
			/* As elsewhere: a lost launch answer keeps polling rather than
			 * reporting a result it does not have. */
			self.setBusy(true, { error: error.message });
			ui.addNotification(null, E('p', {}, [ error.message ]), 'error');
		});
	},

	/* ---- tabs ------------------------------------------------------------ */

	selectTab: function(name) {
		this.activeTab = name;
		(this.tabPanels || []).forEach(function(panel) {
			panel.node.style.display = panel.name === name ? '' : 'none';
			panel.node.setAttribute('aria-hidden', panel.name === name ? 'false' : 'true');
		});
		(this.tabButtons || []).forEach(function(entry) {
			entry.node.setAttribute('aria-selected', entry.name === name ? 'true' : 'false');
			entry.node.className = 'btn cbi-button apn-tab' +
				(entry.name === name ? ' cbi-button-action apn-tab-active' : '');
		});
	},

	render: function(data) {
		var self = this;
		var status = data[1];
		var action = data[2];
		var database = data[3];
		var targets = data[4];
		var modemInventory = data[5];
		var m = new form.Map('apn-autoconfig', null,
			_('How the program behaves on its own, without anyone opening this page.'));
		var s = m.section(form.NamedSection, 'main', 'apn_autoconfig', _('Configuration'));
		var o;
		self.profileApplySupported = status && !status.error && targetCapability(status, 'profile_apply');
		self.policySupported = roamingPolicySupported(status);
		self.policyDirty = false;
		self.databaseStatus = database;
		self.currentStatus = status;
		self.currentAction = action;
		self.targetInventory = targets;
		self.hardwareIntegration = status && status.hardware_integration || '';
		self.modemInventory = modemInventory;

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
		o.value('auto', _('Automatic (only one writable target)'));
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
		o.description = _('Automatic mode refuses to choose when more than one writable cellular target exists.');

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

		self.reconcileButton = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'type': 'button',
			'click': function(ev) { ev.preventDefault(); self.confirmAction('reconcile'); }
		}, [ _('Re-detect and verify APN') ]);
		self.manualButton = E('button', {
			'class': 'btn cbi-button cbi-button-neutral',
			'type': 'button',
			'click': function(ev) { ev.preventDefault(); self.openManualApn(); }
		}, [ _('Enter an APN yourself') ]);
		self.resetButton = null;
		self.databaseCheckButton = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'type': 'button',
			'click': function(ev) { ev.preventDefault(); self.startAction('database-check'); }
		}, [ _('Check for updates') ]);
		self.databaseInstallButton = E('button', {
			'class': 'btn cbi-button cbi-button-positive',
			'type': 'button',
			'click': function(ev) { ev.preventDefault(); self.confirmDatabaseInstall(); }
		}, [ _('Install update') ]);
		/* Kept as fields so a refresh can relabel the default option: what
		 * "OpenWrt default" means depends on the backend. */
		self.policyCustomOption = E('option', { 'value': 'custom', 'disabled': 'disabled' },
			[ _('Custom configuration (unchanged)') ]);
		self.policyDefaultOption = E('option', { 'value': 'default' }, [ defaultPolicyOptionLabel(status) ]);
		self.policySelect = E('select', {
			'class': 'cbi-input-select',
			'change': function() {
				self.policyDirty = true;
				self.updatePolicyControls();
			}
		}, [
			self.policyCustomOption,
			self.policyDefaultOption,
			E('option', { 'value': 'allow' }, [ _('Explicitly allow') ]),
			E('option', { 'value': 'block' }, [ _('Explicitly block') ])
		]);
		/* LuCI's E()/dom.attr() serializes false as selected="false". HTML
		 * boolean attributes are true whenever present, so assigning the value
		 * after construction is required to avoid selecting the last option. */
		self.setPolicyOptions(status);
		self.policyButton = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'type': 'button',
			'click': function(ev) { ev.preventDefault(); self.confirmRoamingPolicy(); }
		}, [ _('Apply roaming policy') ]);
		self.policyDescription = E('p', {}, [ roamingPolicyDescription(status) ]);

		self.modemBox = E('div', {}, self.modemAreaNodes(modemInventory, status));
		self.apnBox = E('div', {}, self.apnAreaNodes(status));
		self.simBox = E('div', {}, self.simAreaNodes(status));
		self.databaseBox = E('div', {}, self.databaseNodes(database));
		self.stripBox = E('div', {}, self.stripNodes(status, action));
		self.modemPollPending = false;
		self.setBusy(!action || !!action.error || !!action.busy, action);

		/* Poll only cheap action state continuously. A page loaded during modem
		 * return gets one delayed full-status retry; complete initial state does
		 * not cause periodic QMI/AT identity traffic. */
		self.panelPollCount = 0;
		self.panelRetryPending = !status || !!status.error ||
			status.signal_quality == null || status.signal_quality === '';
		poll.add(function() { return self.refreshStatus(); }, 2);
		poll.add(function() {
			return self.modemPollPending ? self.refreshProvisioning() : Promise.resolve();
		}, 3);

		return m.render().then(function(mapNode) {
			/* Four areas, one question each: what is the hardware doing, which
			 * profile did we choose, whose subscription is this, and how should
			 * the program behave on its own. */
			var areas = [
				{ name: 'modem', label: _('Modem'), nodes: [ self.modemBox ] },
				{ name: 'apn', label: _('APN'), nodes: [
					self.apnBox,
					E('h4', {}, [ _('Provider database') ]),
					E('p', {}, [ _('The signed provider package can be checked and updated independently from the program and LuCI. Updating it does not change the active APN.') ]),
					self.databaseBox
				] },
				{ name: 'sim', label: _('SIM'), nodes: [ self.simBox ] },
				{ name: 'settings', label: _('Settings'), nodes: [ mapNode ] }
			];

			self.tabPanels = [];
			self.tabButtons = [];
			var panels = areas.map(function(area) {
				var panel = E('div', {
					'class': 'cbi-section apn-card apn-panel',
					'role': 'tabpanel'
				}, area.nodes);
				self.tabPanels.push({ name: area.name, node: panel });
				return panel;
			});
			var buttons = areas.map(function(area) {
				var button = E('button', {
					'class': 'btn cbi-button apn-tab',
					'type': 'button',
					'role': 'tab',
					'click': function(ev) { ev.preventDefault(); self.selectTab(area.name); }
				}, [ area.label ]);
				self.tabButtons.push({ name: area.name, node: button });
				return button;
			});

			var page = E('div', { 'class': 'apn-autoconfig-page' }, [
				E('style', { 'type': 'text/css' }, [
					'.apn-autoconfig-page .apn-card{margin:0 0 1rem 0!important;padding:1rem}' +
					'.apn-autoconfig-page .apn-card>h3{margin-top:0}' +
					'.apn-autoconfig-page .apn-strip{display:flex;flex-wrap:wrap;gap:1rem 2rem;padding:.75rem 1rem;' +
						'margin-bottom:1rem;border:1px solid rgba(128,128,128,.35);border-radius:4px}' +
					'.apn-autoconfig-page .apn-strip-item{display:flex;flex-direction:column;min-width:9rem}' +
					'.apn-autoconfig-page .apn-strip-label{font-size:85%;opacity:.7}' +
					'.apn-autoconfig-page .apn-strip-value{font-weight:600}' +
					'.apn-autoconfig-page .apn-strip-good .apn-strip-value{color:#2d8a43}' +
					'.apn-autoconfig-page .apn-strip-warn .apn-strip-value{color:#b58100}' +
					'.apn-autoconfig-page .apn-strip-bad .apn-strip-value{color:#b11}' +
					'.apn-autoconfig-page .apn-tabs{display:flex;flex-wrap:wrap;gap:.5rem;margin-bottom:1rem}' +
					'.apn-autoconfig-page .apn-label strong{font-weight:600}' +
					'.apn-autoconfig-page .apn-help-label{display:inline-flex;align-items:center;gap:.4em}' +
					'.apn-autoconfig-page .apn-help-toggle{padding:0 .5em;line-height:1.4;min-width:1.8em}' +
					'.apn-autoconfig-page .apn-help-text{margin:.4rem 0 0 0;font-weight:400;opacity:.85}' +
					'.apn-autoconfig-page .apn-details{margin-top:.75rem}' +
					'.apn-autoconfig-page .apn-details summary{cursor:pointer;font-weight:600;padding:.35rem 0}' +
					'.apn-autoconfig-page .apn-modem-entry{padding:.75rem 0;border-top:1px solid rgba(128,128,128,.25)}' +
					'.apn-autoconfig-page .apn-modem-title{margin:0 0 .5rem 0}' +
					'.apn-autoconfig-page .apn-modem-radio{margin-top:.75rem}' +
					'.apn-autoconfig-page .apn-modem-radio h5{margin:0 0 .35rem 0;font-weight:600;opacity:.85}' +
					'.apn-autoconfig-page .apn-button-row{display:flex;flex-wrap:wrap;gap:.5rem;margin-top:1rem}' +
					'.apn-autoconfig-page .apn-policy-controls{display:flex;flex-wrap:wrap;align-items:center;gap:.5rem;margin-top:1rem}' +
					'.apn-autoconfig-page .apn-state-good{color:#2d8a43;font-weight:600}' +
					'.apn-autoconfig-page .apn-state-bad{color:#b11;font-weight:600}' +
					'.apn-autoconfig-page .apn-action-status{min-height:1.5em}' +
					'@media(max-width:600px){.apn-autoconfig-page .apn-card{padding:.75rem}' +
						'.apn-autoconfig-page .apn-table .apn-label{width:45%!important}}'
				]),
				E('h2', {}, [ _('APN Auto-Config') ]),
				self.stripBox,
				E('div', { 'class': 'apn-tabs', 'role': 'tablist' }, buttons)
			].concat(panels));

			self.selectTab('modem');
			return page;
		});
	}
});
