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

function call(command, args) {
	return fs.exec(command, args).then(function(result) {
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

function row(label, value) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left apn-label', 'style': 'width:40%' }, [ E('strong', {}, [ label ]) ]),
		E('td', { 'class': 'td left apn-value' }, [ valueNode(value) ])
	]);
}

function table(rows) {
	return E('table', { 'class': 'table apn-table' }, rows);
}

function networkLabel(name, id) {
	if (name && id)
		return '%s (%s)'.format(name, id);
	return name || id || '';
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
	case 'invalid': return _('Invalid configuration');
	default: return _('Unknown');
	}
}

function policyValue(status) {
	switch (status && status.roaming_policy) {
	case 'explicit-allow': return 'allow';
	case 'explicit-block': return 'block';
	default: return 'default';
	}
}

function targetCapability(status, name) {
	/* A staggered upgrade from 0.9.0 has no target_capabilities yet and keeps
	 * the previously available ModemManager controls until status is refreshed
	 * from the new core. */
	return !status || !status.target_capabilities || status.target_capabilities[name] === true;
}

function trustLabel(value, positive, negative) {
	return E('span', { 'class': value ? 'apn-state-good' : 'apn-state-bad' }, [ value ? positive : negative ]);
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('apn-autoconfig'),
			call(queryCommand, [ 'status' ]).catch(function(error) { return { error: error.message }; }),
			call(queryCommand, [ 'action-status' ]).catch(function(error) { return { error: error.message }; }),
			call(queryCommand, [ 'database-status' ]).catch(function(error) { return { error: error.message }; }),
			call(queryCommand, [ 'targets' ]).catch(function(error) { return { error: error.message }; })
		]);
	},

	statusWarnings: function(status) {
		var nodes = [];
		if (!status || status.error)
			return [ E('div', { 'class': 'alert-message warning' }, [
				_('Status is temporarily unavailable: %s').format(status && status.error || _('unknown error'))
			]) ];

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

	connectionNodes: function(status) {
		if (!status || status.error)
			return this.statusWarnings(status);
		return this.statusWarnings(status).concat([
			table([
				row(_('SIM / eSIM provider'), status.operator_name),
				row(_('Home network'), networkLabel(status.home_operator_name, status.home_operator_id)),
				row(_('Serving network'), networkLabel(status.serving_operator_name, status.serving_operator_id)),
				row(_('Registration'), status.registration_state),
				row(_('Access technologies'), (status.access_technologies || '').replace(/,/g, ' + ')),
				row(_('Signal quality'), signalQuality(status.signal_quality)),
				row(_('Mobile interface'), '%s: %s'.format(status.interface, status.interface_up ? _('up') : _('down or pending')))
			]),
			E('details', { 'class': 'apn-details' }, [
				E('summary', {}, [ _('SIM and modem details') ]),
				table([
					row(_('ICCID'), sensitiveIdentifier(status.iccid, _('ICCID'))),
					row(_('IMSI'), sensitiveIdentifier(status.imsi, _('IMSI'))),
					row(_('EID'), sensitiveIdentifier(status.eid, _('EID'))),
					row(_('SIM slot / backend index'), status.sim_index),
					row(_('Modem / control identifier'), status.modem_index),
					row(_('Engine target'), status.target_id),
					row(_('Protocol / backend'), '%s / %s'.format(status.target_protocol, status.target_backend)),
					row(_('Implementation / validation'), '%s / %s'.format(
						status.target_implementation_state || '—', status.target_validation_state || '—')),
					row(_('Hardware validated'), status.target_hardware_validated ? _('yes') : _('no')),
					row(_('Effective data device'), status.l3_device || status.device),
					row(_('Manual operator lock (PLMN)'), status.configured_plmn)
				])
			])
		]);
	},

	apnNodes: function(status) {
		if (!status || status.error)
			return [ E('p', { 'class': 'alert-message warning' }, [ _('APN status is unavailable.') ]) ];
		return [ table([
			row(_('Configured APN'), status.configured_apn || _('<empty>')),
			row(_('Cached APN for this SIM'), status.cached_apn),
			row(_('Last result'), status.last_result),
			row(_('Reconciled APN'), status.reconciled_apn),
			row(_('Reconciled SIM'), sensitiveIdentifier(status.reconciled_iccid, _('SIM identifier')))
		]) ];
	},

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

	databaseNodes: function(database, status) {
		if (!database || database.error)
			return [ this.databaseAlert(database) ];
		var rows = [
			row(_('Installed package version'), database.installed_package_version),
			row(_('Database version'), database.database_version),
			row(_('Data release date'), databaseReleaseDate(database.database_version)),
			row(_('Last update check'), formatTimestamp(database.checked_at) || _('Not checked yet')),
			row(_('Last installation through this page'), formatTimestamp(database.installed_at) || _('Not recorded')),
			row(_('Signed package feed'), trustLabel(database.feed_configured, _('Configured'), _('Not configured'))),
			row(_('Repository signing key'), trustLabel(database.key_trusted, _('Trusted'), _('Not installed')))
		];
		if (database.update_available)
			rows.splice(3, 0, row(_('Available package version'), database.available_package_version));

		var nodes = [ this.databaseAlert(database), table(rows) ];
		if (status && !status.error)
			nodes.push(E('details', { 'class': 'apn-details' }, [
				E('summary', {}, [ _('Database technical details') ]),
				table([
					row(_('Database format'), status.database_format ? 'v%s'.format(status.database_format) : ''),
					row(_('Sources'), status.database_sources),
					row(_('Source revisions'), status.database_revisions),
					row(_('Database path'), status.database_path),
					row(_('Feed URL'), database.feed_url)
				])
			]));
		nodes.push(E('div', { 'class': 'apn-button-row' }, [
			this.databaseCheckButton,
			this.databaseInstallButton
		]));
		return nodes;
	},

	actionLabel: function(action) {
		switch (action) {
		case 'reconcile': return _('APN re-detection');
		case 'modem-reset': return _('modem power-cycle');
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
		if (this.reconcileButton)
			this.reconcileButton.disabled = this.busy || !this.profileApplySupported;
		if (this.resetButton)
			this.resetButton.disabled = this.busy || !this.profileApplySupported;
		this.updatePolicyControls();
		this.updateDatabaseControls();
		if (this.actionStatus)
			dom.content(this.actionStatus, [ this.actionDescription(action) ]);
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

	setDatabaseStatus: function(database, status) {
		this.databaseStatus = database;
		if (status)
			this.currentStatus = status;
		if (this.databaseBox)
			dom.content(this.databaseBox, this.databaseNodes(database, this.currentStatus));
		this.updateDatabaseControls();
	},

	refreshDatabase: function() {
		var self = this;
		return call(queryCommand, [ 'database-status' ]).catch(function(error) {
			return { error: error.message };
		}).then(function(database) {
			self.setDatabaseStatus(database, null);
		});
	},

	refreshPanels: function() {
		var self = this;
		return Promise.all([
			call(queryCommand, [ 'status' ]).catch(function(error) { return { error: error.message }; }),
			call(queryCommand, [ 'database-status' ]).catch(function(error) { return { error: error.message }; })
		]).then(function(values) {
			var status = values[0];
			dom.content(self.connectionBox, self.connectionNodes(status));
			dom.content(self.apnBox, self.apnNodes(status));
			self.profileApplySupported = status && !status.error && targetCapability(status, 'profile_apply');
			self.policySupported = status && !status.error && status.version === 'v2' &&
				targetCapability(status, 'profile_write');
			if (self.policySelect && self.policySupported) {
				self.policySelect.value = policyValue(status);
				self.policyDirty = false;
			}
			self.setDatabaseStatus(values[1], status);
			self.updatePolicyControls();
		});
	},

	refreshStatus: function() {
		var self = this;
		return call(queryCommand, [ 'action-status' ]).then(function(action) {
			var wasBusy = self.busy;
			var databaseAction = action.action === 'database-check' || action.action === 'database-install';
			self.setBusy(action.busy, action);

			if (wasBusy && !action.busy)
				return self.refreshPanels().then(function() { self.setBusy(false, action); });
			if (action.busy && databaseAction)
				return self.refreshDatabase().then(function() { self.setBusy(true, action); });
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

	render: function(data) {
		var self = this;
		var status = data[1];
		var action = data[2];
		var database = data[3];
		var targets = data[4];
		var m = new form.Map('apn-autoconfig', _('Settings'),
			_('Automatic APN selection through the target-aware cellular engine.'));
		var s = m.section(form.NamedSection, 'main', 'apn_autoconfig', _('Configuration'));
		var o;
		self.profileApplySupported = status && !status.error && targetCapability(status, 'profile_apply');
		self.policySupported = status && !status.error && status.version === 'v2' &&
			targetCapability(status, 'profile_write');
		self.policyDirty = false;
		self.databaseStatus = database;
		self.currentStatus = status;
		self.hardwareIntegration = status && status.hardware_integration || '';

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
		self.resetButton = null;
		if (self.hardwareIntegration)
			self.resetButton = E('button', {
				'class': 'btn cbi-button cbi-button-negative',
				'type': 'button',
				'click': function(ev) { ev.preventDefault(); self.confirmAction('modem-reset'); }
			}, [ _('Power-cycle WH3000 modem and re-read SIM') ]);
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
		self.policySelect = E('select', {
			'class': 'cbi-input-select',
			'change': function() {
				self.policyDirty = true;
				self.updatePolicyControls();
			}
		}, [
			E('option', { 'value': 'default' }, [ _('OpenWrt default (allowed)') ]),
			E('option', { 'value': 'allow' }, [ _('Explicitly allow') ]),
			E('option', { 'value': 'block' }, [ _('Explicitly block') ])
		]);
		/* LuCI's E()/dom.attr() serializes false as selected="false". HTML
		 * boolean attributes are true whenever present, so assigning the value
		 * after construction is required to avoid selecting the last option. */
		self.policySelect.value = policyValue(status);
		self.policyButton = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'type': 'button',
			'click': function(ev) { ev.preventDefault(); self.confirmRoamingPolicy(); }
		}, [ _('Apply roaming policy') ]);

		self.connectionBox = E('div', {}, self.connectionNodes(status));
		self.apnBox = E('div', {}, self.apnNodes(status));
		self.databaseBox = E('div', {}, self.databaseNodes(database, status));
		self.actionStatus = E('p', { 'class': 'notice apn-action-status' }, [ self.actionDescription(action) ]);
		self.setBusy(!action || !!action.error || !!action.busy, action);

		poll.add(function() { return self.refreshStatus(); }, 2);

		return m.render().then(function(mapNode) {
			var mobileActionButtons = [ self.reconcileButton ];
			if (self.resetButton)
				mobileActionButtons.push(self.resetButton);
			return E('div', { 'class': 'apn-autoconfig-page' }, [
				E('style', { 'type': 'text/css' }, [
					'.apn-autoconfig-page .apn-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(22rem,1fr));gap:1rem;margin-bottom:1rem}' +
					'.apn-autoconfig-page .apn-card{margin:0!important;padding:1rem}' +
					'.apn-autoconfig-page .apn-card>h3{margin-top:0}' +
					'.apn-autoconfig-page .apn-full{grid-column:1/-1}' +
					'.apn-autoconfig-page .apn-label strong{font-weight:600}' +
					'.apn-autoconfig-page .apn-details{margin-top:.75rem}' +
					'.apn-autoconfig-page .apn-details summary{cursor:pointer;font-weight:600;padding:.35rem 0}' +
					'.apn-autoconfig-page .apn-button-row{display:flex;flex-wrap:wrap;gap:.5rem;margin-top:1rem}' +
					'.apn-autoconfig-page .apn-policy-controls{display:flex;flex-wrap:wrap;align-items:center;gap:.5rem;margin-top:1rem}' +
					'.apn-autoconfig-page .apn-state-good{color:#2d8a43;font-weight:600}' +
					'.apn-autoconfig-page .apn-state-bad{color:#b11;font-weight:600}' +
					'.apn-autoconfig-page .apn-action-status{min-height:1.5em}' +
					'@media(max-width:600px){.apn-autoconfig-page .apn-grid{grid-template-columns:1fr}.apn-autoconfig-page .apn-card{padding:.75rem}.apn-autoconfig-page .apn-table .apn-label{width:45%!important}}'
				]),
				E('h2', {}, [ _('APN Auto-Config') ]),
				E('div', { 'class': 'apn-grid' }, [
					E('section', { 'class': 'cbi-section apn-card' }, [
						E('h3', {}, [ _('Mobile connection') ]),
						self.connectionBox
					]),
					E('section', { 'class': 'cbi-section apn-card' }, [
						E('h3', {}, [ _('Current APN') ]),
						self.apnBox
					]),
					E('section', { 'class': 'cbi-section apn-card apn-full' }, [
						E('h3', {}, [ _('Provider database') ]),
						E('p', {}, [ _('The signed provider package can be checked and updated independently from the program and LuCI. Updating it does not change the active APN.') ]),
						self.databaseBox
					]),
					E('section', { 'class': 'cbi-section apn-card' }, [
						E('h3', {}, [ _('Roaming data policy') ]),
						E('p', {}, [ _('This edits the canonical network.%s.allow_roaming option used by netifd and ModemManager. APN profiles never change it automatically.').format(status.interface || 'wwan') ]),
						E('div', { 'class': 'apn-policy-controls' }, [ self.policySelect, self.policyButton ])
					]),
					E('section', { 'class': 'cbi-section apn-card' }, [
						E('h3', {}, [ _('Actions') ]),
						self.actionStatus,
						E('div', { 'class': 'apn-button-row' }, mobileActionButtons)
					])
				]),
				mapNode
			]);
		});
	}
});
