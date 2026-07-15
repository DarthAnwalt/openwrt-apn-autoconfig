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

function row(label, value) {
	return E('tr', {}, [
		E('td', { 'class': 'td left', 'style': 'width:35%' }, [ label ]),
		E('td', { 'class': 'td left' }, [ text(value) ])
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('apn-autoconfig'),
			call(queryCommand, [ 'status' ]).catch(function(error) { return { error: error.message }; }),
			call(queryCommand, [ 'action-status' ]).catch(function(error) { return { error: error.message }; })
		]);
	},

	statusNodes: function(status) {
		if (!status || status.error)
			return [ E('div', { 'class': 'alert-message warning' }, [
				_('Status is temporarily unavailable: %s').format(status && status.error || _('unknown error'))
			]) ];

		return [ E('table', { 'class': 'table' }, [
			row(_('SIM / eSIM provider'), status.operator_name),
			row(_('Home operator'), status.operator_id),
			row(_('ICCID'), status.iccid),
			row(_('IMSI'), status.imsi),
			row(_('EID'), status.eid),
			row(_('ModemManager SIM index'), status.sim_index),
			row(_('Configured APN'), status.configured_apn || _('<empty>')),
			row(_('Cached APN for this SIM'), status.cached_apn),
			row(_('Mobile interface'), '%s: %s'.format(status.interface, status.interface_up ? _('up') : _('down or pending'))),
			row(_('Last result'), status.last_result),
			row(_('Reconciled SIM'), status.reconciled_iccid),
			row(_('Reconciled APN'), status.reconciled_apn)
		]) ];
	},

	actionDescription: function(action) {
		if (!action || action.error)
			return action && action.error || _('Operation status is unavailable');

		switch (action.state) {
		case 'starting':
		case 'queued':
			return _('The %s operation is queued.').format(action.action);
		case 'running':
			return _('The %s operation is running. Please wait; this may take over a minute.').format(action.action);
		case 'external':
			return _('An APN or modem operation started from SSH or the physical button is running.');
		case 'success':
			return _('The last %s operation completed successfully.').format(action.action);
		case 'failed':
			return _('The last %s operation failed: %s').format(action.action, action.message || _('see system log'));
		default:
			return _('No operation is running.');
		}
	},

	setBusy: function(busy, action) {
		this.busy = !!busy;
		if (this.reconcileButton)
			this.reconcileButton.disabled = this.busy;
		if (this.resetButton)
			this.resetButton.disabled = this.busy;
		if (this.actionStatus)
			dom.content(this.actionStatus, [ this.actionDescription(action) ]);
	},

	refreshStatus: function() {
		var self = this;
		return call(queryCommand, [ 'action-status' ]).then(function(action) {
			var wasBusy = self.busy;
			self.setBusy(action.busy, action);

			if (wasBusy && !action.busy)
				return call(queryCommand, [ 'status' ]).then(function(status) {
					dom.content(self.statusBox, self.statusNodes(status));
				});
		}).catch(function(error) {
			/* A transient polling failure is not evidence that a long-running
			 * operation ended. Keep controls disabled until the core says so. */
			self.setBusy(self.busy, { error: error.message });
		});
	},

	startAction: function(action) {
		var self = this;
		self.setBusy(true, { state: 'starting', action: action });

		return call(controlCommand, [ action ]).then(function(result) {
			self.setBusy(result.busy, result);
			if (!result.accepted && !result.busy)
				throw new Error(result.message || _('The operation could not be started'));
			if (result.accepted && !result.busy)
				return call(queryCommand, [ 'status' ]).then(function(status) {
					dom.content(self.statusBox, self.statusNodes(status));
				});
		}).catch(function(error) {
			/* The launch response may have been lost after the job was accepted.
			 * Polling will safely determine when controls may be re-enabled. */
			self.setBusy(true, { error: error.message });
			ui.addNotification(null, E('p', {}, [ error.message ]), 'error');
		});
	},

	confirmAction: function(action) {
		var self = this;
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

	render: function(data) {
		var self = this;
		var status = data[1];
		var action = data[2];
		var m = new form.Map('apn-autoconfig', _('Configuration'),
			_('Automatic APN selection for a ModemManager mobile interface. Long operations run in the background and cannot overlap.'));
		var s = m.section(form.NamedSection, 'main', 'apn_autoconfig', _('Settings'));
		var o;

		s.tab('general', _('General'));
		s.tab('advanced', _('Advanced'));

		o = s.taboption('general', form.Flag, 'button_enabled', _('Enable physical modem-reset button'));
		o.default = o.disabled;
		o.rmempty = false;
		o.description = _('On the tested WH3000 Pro, releasing BTN_0 power-cycles the modem and then reconciles the APN. Keep disabled on unverified hardware.');

		o = s.taboption('general', form.Value, 'interface', _('Mobile interface'));
		o.default = 'wwan';
		o.rmempty = false;
		o.datatype = 'uciname';

		o = s.taboption('general', form.Value, 'device', _('Mobile data device'));
		o.default = 'wwan0';
		o.rmempty = false;
		o.datatype = 'uciname';

		o = s.taboption('general', form.ListValue, 'use_mwan3', _('mwan3-aware connectivity test'));
		o.value('auto', _('Automatic'));
		o.value('always', _('Always use mwan3'));
		o.value('never', _('Never use mwan3'));
		o.default = 'auto';

		o = s.taboption('advanced', form.Value, 'button_name', _('Button event name'));
		o.default = 'BTN_0';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'modem_power_path', _('Modem power GPIO value path'));
		o.default = '/sys/class/gpio/modem_power/value';
		o.rmempty = false;
		o.description = _('Board-specific exported GPIO path. This is not a raw GPIO pin number.');

		o = s.taboption('advanced', form.Value, 'modem_power_off_seconds', _('Power-off duration'));
		o.default = '5';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'modem_wait_seconds', _('Maximum modem return wait'));
		o.default = '90';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'wait_seconds', _('Maximum interface-up wait'));
		o.default = '35';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'test_url', _('Connectivity test URL'));
		o.default = 'https://connectivitycheck.gstatic.com/generate_204';
		o.rmempty = false;

		self.statusBox = E('div', { 'class': 'cbi-section' }, self.statusNodes(status));
		self.actionStatus = E('p', { 'class': 'notice' }, [ self.actionDescription(action) ]);
		self.reconcileButton = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'type': 'button',
			'click': function(ev) { ev.preventDefault(); self.confirmAction('reconcile'); }
		}, [ _('Re-detect and verify APN') ]);
		self.resetButton = E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'type': 'button',
			'click': function(ev) { ev.preventDefault(); self.confirmAction('modem-reset'); }
		}, [ _('Power-cycle modem and re-read SIM') ]);
		self.setBusy(!action || !!action.error || !!action.busy, action);

		poll.add(function() { return self.refreshStatus(); }, 2);

		return m.render().then(function(mapNode) {
			return E([], [
				E('h2', {}, [ _('APN Auto-Config') ]),
				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, [ _('Current SIM and APN') ]),
					self.statusBox
				]),
				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, [ _('Actions') ]),
					self.actionStatus,
					E('div', { 'class': 'cbi-page-actions' }, [
						self.reconcileButton,
						' ',
						self.resetButton
					])
				]),
				mapNode
			]);
		});
	}
});
