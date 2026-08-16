'use strict';

/* Regression tests for the LuCI modem area and manual APN entry.
 *
 * These assert the safety properties the view is responsible for: a control is
 * never offered for something the runtime would refuse, an interface the user
 * created is never offered for adoption or removal even though it can now be
 * started and stopped, the privileged wrapper is only ever given a fixed verb
 * and a modem identity, and a lost launch answer never reports success. */

var assert = require('assert');
var fs = require('fs');
var path = require('path');

var root = path.resolve(__dirname, '..');
var source = fs.readFileSync(path.join(root,
	'luci-app-apn-autoconfig/htdocs/luci-static/resources/view/network/apn-autoconfig.js'), 'utf8');

if (!String.prototype.format) {
	Object.defineProperty(String.prototype, 'format', {
		value: function() {
			var args = arguments;
			var index = 0;
			return this.replace(/%s/g, function() { return String(args[index++]); });
		},
		configurable: true
	});
}

function element(tag, attrs, children) {
	attrs = attrs || {};
	children = children || [];

	if (Array.isArray(tag))
		return { tag: 'fragment', children: children };

	var node = { tag: tag, attrs: {}, children: children, style: {} };
	node.setAttribute = function(key, value) { this.attrs[key] = String(value); };
	Object.keys(attrs).forEach(function(key) {
		var value = attrs[key];
		if (value == null)
			return;
		if (typeof value === 'function')
			node[key] = value;
		else
			node.attrs[key] = String(value);
	});
	return node;
}

/* Every button anywhere in a rendered subtree, with its label. */
function collectButtons(node, found) {
	found = found || [];
	if (!node || typeof node !== 'object')
		return found;
	if (Array.isArray(node)) {
		node.forEach(function(child) { collectButtons(child, found); });
		return found;
	}
	if (node.tag === 'button')
		found.push(node);
	collectButtons(node.children, found);
	return found;
}

function collectText(node, parts) {
	parts = parts || [];
	if (node == null)
		return parts;
	if (typeof node === 'string') {
		parts.push(node);
		return parts;
	}
	if (Array.isArray(node)) {
		node.forEach(function(child) { collectText(child, parts); });
		return parts;
	}
	if (typeof node === 'object')
		collectText(node.children, parts);
	return parts;
}

/* Only the action row. The modem identity carries its own reveal toggle,
 * because identifiers stay masked until explicitly shown. */
function actionRows(node, found) {
	found = found || [];
	if (!node || typeof node !== 'object')
		return found;
	if (Array.isArray(node)) {
		node.forEach(function(child) { actionRows(child, found); });
		return found;
	}
	if (node.attrs && String(node.attrs['class'] || '').indexOf('apn-button-row') !== -1)
		found.push(node);
	actionRows(node.children, found);
	return found;
}

function actionButtons(nodes) {
	var buttons = [];
	actionRows(nodes).forEach(function(row) { collectButtons(row, buttons); });
	return buttons;
}

function buttonLabels(nodes) {
	return actionButtons(nodes).map(function(button) {
		return collectText(button.children).join(' ').trim();
	});
}

function makeForm() {
	function option() {
		return { value: function() {} };
	}
	function section() {
		return { tab: function() {}, taboption: option };
	}
	function Map() {
		this.section = section;
		this.render = function() { return Promise.resolve(element('form')); };
	}
	return {
		Map: Map,
		NamedSection: function() {},
		Flag: function() {},
		Value: function() {},
		ListValue: function() {}
	};
}

function loadView(execHandler) {
	var view = { extend: function(value) { return value; } };
	var ui = {
		modals: [],
		notifications: [],
		hideModal: function() {},
		showModal: function(title, children) { this.modals.push({ title: title, children: children }); },
		addNotification: function(_id, node) { this.notifications.push(collectText(node).join(' ')); }
	};
	var execCalls = [];
	var fsStub = {
		exec: function(command, args, env) {
			execCalls.push({ command: command, args: args, env: env });
			var handled = execHandler ? execHandler(command, args, env) : null;
			if (handled == null)
				handled = { code: 0, stdout: '{}' };
			if (handled instanceof Error)
				return Promise.reject(handled);
			return Promise.resolve(handled);
		}
	};
	var app = Function('view', 'form', 'fs', 'uci', 'ui', 'poll', 'dom', 'E', '_', source)(
		view,
		makeForm(),
		fsStub,
		{},
		ui,
		{ add: function() {} },
		{ content: function(node, children) { node.children = children; } },
		element,
		function(value) { return value; }
	);
	app.testUi = ui;
	app.testExecCalls = execCalls;
	return app;
}

function modemFixture(plan, operation) {
	return {
		modem_id: 'usb-serial:1-1.2:2c7c:0801:SERIAL01',
		evidence_tier: 'usb-serial',
		protocol: 'qmi',
		owner_state: 'none',
		capabilities: { inventory: true, reset: false },
		plan: plan,
		operation: operation || { busy: false, state: 'idle' }
	};
}

function modemArea(plan, operation, extra) {
	var modem = Object.assign(modemFixture(plan, operation), extra || {});
	return loadView().modemAreaNodes({ version: 'v1', modems: [ modem ] });
}

/* An unconfigured modem is the only case that offers setup. */
var setupNodes = modemArea({
	can_provision: true, reason: 'ok', section: 'apnmodem1', protocol: 'qmi',
	can_control_bearer: false, connection_section: '', connection_owned: false
});
assert.deepStrictEqual(buttonLabels(setupNodes), [ 'Set up this modem' ],
	'an unconfigured modem must offer exactly one setup control');
assert.ok(collectText(setupNodes).join(' ').indexOf('SERIAL01') === -1,
	'the modem identity must stay masked until the user reveals it');
assert.ok(collectText(setupNodes).join(' ').indexOf('apnmodem1') !== -1,
	'the view must name the interface it would create before the user agrees');

/* Bearer control no longer depends on who created the interface. An interface
 * the user made gets connect, disconnect and reconnect - and nothing that would
 * change its configuration. */
var foreignNodes = modemArea(
	{ can_provision: false, reason: 'already_configured',
	  can_control_bearer: true, connection_section: 'wwan', connection_owned: false },
	null,
	{ owner_state: 'modemmanager', netifd_interface: 'wwan' });
assert.deepStrictEqual(buttonLabels(foreignNodes), [ 'Connect', 'Reconnect', 'Disconnect' ],
	'a user-created cellular interface must offer bearer control and nothing else');
var foreignText = collectText(foreignNodes).join(' ');
assert.ok(foreignText.indexOf('wwan') !== -1,
	'the card must name the interface the modem is bound to');
assert.ok(!/only reported here/.test(foreignText),
	'a modem that can now be controlled must not be described as merely reported');

/* A modem this package set up keeps removal in addition. */
var ownedNodes = modemArea({
	can_provision: false, reason: 'already_provisioned', existing_section: 'apnmodem1',
	can_control_bearer: true, connection_section: 'apnmodem1', connection_owned: true
});
assert.deepStrictEqual(buttonLabels(ownedNodes),
	[ 'Connect', 'Reconnect', 'Disconnect', 'Remove setup' ],
	'a project-owned modem must offer bearer control and removal');

/* Whatever the reason, a modem the runtime would refuse gets no control and an
 * explanation. The backend decides; the view never re-derives the rule. */
[ 'ambiguous', 'conflicting_owner', 'unsupported_protocol', 'no_device' ]
	.forEach(function(reason) {
		var nodes = modemArea({
			can_provision: false, reason: reason,
			can_control_bearer: false, connection_section: '', connection_owned: false
		});
		assert.deepStrictEqual(buttonLabels(nodes), [],
			'a modem refused for ' + reason + ' must offer no controls at all');
		assert.ok(collectText(nodes).join(' ').trim().length > 0,
			'a modem refused for ' + reason + ' must be explained instead of silently empty');
	});

/* A staged project-owned section has no profile yet. The backend refuses to
 * start it, so the page must not offer to. */
var stagedNodes = modemArea({
	can_provision: false, reason: 'already_provisioned', existing_section: 'apnmodem1',
	can_control_bearer: false, connection_section: '', connection_owned: true
});
assert.deepStrictEqual(buttonLabels(stagedNodes), [ 'Remove setup' ],
	'a staged section must not be startable from the page');

/* A missing optional package explains itself rather than showing dead buttons. */
var absentNodes = loadView().modemAreaNodes({ error: 'not installed' });
assert.deepStrictEqual(buttonLabels(absentNodes), [],
	'an absent modem package must not render controls');
assert.ok(collectText(absentNodes).join(' ').indexOf('apn-autoconfig-modem') !== -1,
	'an absent modem package must be named in the explanation');

/* Controls stay disabled while that modem already has an operation running. */
var busyNodes = modemArea(
	{ can_provision: false, reason: 'already_provisioned', existing_section: 'apnmodem1',
	  can_control_bearer: true, connection_section: 'apnmodem1', connection_owned: true },
	{ busy: true, state: 'running' }
);
assert.ok(actionButtons(busyNodes).every(function(button) { return button.disabled === true; }),
	'controls must be disabled while an operation is running for that modem');

/* The case that let a real defect through: the modem itself is idle, but the
 * engine is busy — a reconcile, a power-cycle, an SSH command or the physical
 * button — and they all take the same global lock. A bearer control offered
 * then is a control that will fail on that lock. Both the render path and the
 * poll path have to close it, because either can be the one that runs. */
var idlePlan = {
	can_provision: false, reason: 'already_configured',
	can_control_bearer: true, connection_section: 'wwan', connection_owned: false
};

var engineBusyApp = loadView();
engineBusyApp.busy = true;
var engineBusyNodes = engineBusyApp.modemAreaNodes({
	version: 'v1',
	modems: [ modemFixture(idlePlan, { busy: false, state: 'idle' }) ]
});
assert.ok(actionButtons(engineBusyNodes).length > 0,
	'the fixture must actually render the controls this asserts about');
assert.ok(actionButtons(engineBusyNodes).every(function(button) { return button.disabled === true; }),
	'a card rendered while the engine is busy must come back disabled');

var pollApp = loadView();
pollApp.busy = false;
pollApp.profileApplySupported = true;
var pollNodes = pollApp.modemAreaNodes({
	version: 'v1',
	modems: [ modemFixture(idlePlan, { busy: false, state: 'idle' }) ]
});
assert.ok(actionButtons(pollNodes).every(function(button) { return button.disabled === false; }),
	'an idle modem and an idle engine must leave the controls usable');
pollApp.setBusy(true, { state: 'running', action: 'reconcile' });
assert.ok(actionButtons(pollNodes).every(function(button) { return button.disabled === true; }),
	'learning that the engine is busy must disable the already-rendered controls');

/* The privileged wrapper only ever receives a fixed verb and a modem identity:
 * the view cannot name a section, device or profile field. */
var actionApp = loadView(function(command, args) {
	if (args && args[0] === 'provision')
		return { code: 0, stdout: JSON.stringify({ accepted: true, busy: true }) };
	return null;
});
var modem = modemFixture({ can_provision: true, reason: 'ok', section: 'apnmodem1', protocol: 'qmi' });
actionApp.modemButtons = [];
Promise.resolve(actionApp.startModemAction(modem, 'provision')).then(function() {
	var calls = actionApp.testExecCalls.filter(function(call) {
		return call.command.indexOf('modem-control') !== -1;
	});
	assert.strictEqual(calls.length, 1, 'exactly one privileged call must be made');
	assert.deepStrictEqual(calls[0].args, [ 'provision', modem.modem_id ],
		'the privileged wrapper must receive only the verb and the modem identity');
	assert.strictEqual(actionApp.modemPollPending, true,
		'an accepted operation must leave polling to decide when it is finished');

	/* A launch answer lost after the job was accepted must not be reported as
	 * a failure that stops tracking, nor as a success. */
	var lostApp = loadView(function() { return new Error('connection lost'); });
	lostApp.modemButtons = [];
	return Promise.resolve(lostApp.startModemAction(modem, 'provision')).then(function() {
		assert.strictEqual(lostApp.modemPollPending, true,
			'a lost launch answer must keep polling rather than invent a result');
		assert.strictEqual(lostApp.testUi.notifications.length, 1,
			'a lost launch answer must be surfaced to the user');

		/* A rejection that is neither accepted nor busy is a real failure. */
		var rejectedApp = loadView(function() {
			return { code: 0, stdout: JSON.stringify({ accepted: false, busy: false, message: 'refused' }) };
		});
		rejectedApp.modemButtons = [];
		return Promise.resolve(rejectedApp.startModemAction(modem, 'provision')).then(function() {
			assert.ok(rejectedApp.testUi.notifications.join(' ').indexOf('refused') !== -1,
				'a non-busy rejection must be reported to the user');
		});
	});
}).then(function() {
	/* Destructive verbs must be confirmed before anything is started. */
	var confirmApp = loadView();
	confirmApp.modemButtons = [];
	var owned = modemFixture({
		can_provision: false, reason: 'already_provisioned', existing_section: 'apnmodem1',
		can_control_bearer: true, connection_section: 'apnmodem1', connection_owned: true
	});
	[ 'provision', 'deprovision', 'disconnect', 'reconnect' ].forEach(function(verb) {
		confirmApp.confirmModemAction(owned, verb);
	});
	assert.strictEqual(confirmApp.testUi.modals.length, 4,
		'every state-changing verb must be confirmed first');
	assert.strictEqual(confirmApp.testExecCalls.length, 0,
		'showing a confirmation must not start anything');

	/* Starting or stopping an interface is not a claim to own it, so the
	 * confirmation has to say which interface it will act on. */
	var namingApp = loadView();
	namingApp.modemButtons = [];
	var foreign = modemFixture({
		can_provision: false, reason: 'already_configured',
		can_control_bearer: true, connection_section: 'wwan', connection_owned: false
	});
	[ 'connect', 'disconnect', 'reconnect' ].forEach(function(verb) {
		namingApp.testUi.modals.length = 0;
		namingApp.confirmModemAction(foreign, verb);
		assert.strictEqual(namingApp.testUi.modals.length, 1,
			verb + ' must be confirmed before it runs');
		var body = collectText(namingApp.testUi.modals[0].children).join(' ');
		assert.ok(body.indexOf('wwan') !== -1,
			verb + ' must name the interface it will act on');
		assert.ok(/no configuration is changed/i.test(body),
			verb + ' must say that it changes no configuration');
	});

	/* ---- manual APN entry ---- */

	function manualApp(execHandler) {
		var app = loadView(execHandler);
		app.currentStatus = { target_id: 'network:wwan' };
		app.profileApplySupported = true;
		app.busy = false;
		app.manualApn = { value: '' };
		app.manualUsername = { value: '' };
		app.manualPassword = { value: '' };
		app.manualAuth = { value: '' };
		app.manualIpType = { value: '' };
		return app;
	}

	/* The password must never reach the argument vector, which any local
	 * process can read through /proc/<pid>/cmdline. */
	var secretApp = manualApp(function() {
		return { code: 0, stdout: JSON.stringify({ accepted: true, busy: true }) };
	});
	secretApp.manualApn.value = 'internet.example';
	secretApp.manualUsername.value = 'someone';
	secretApp.manualPassword.value = 'top-secret-value';
	return Promise.resolve(secretApp.startManualApn(secretApp.manualApnValues())).then(function() {
		var call = secretApp.testExecCalls[secretApp.testExecCalls.length - 1];
		assert.strictEqual(JSON.stringify(call.args).indexOf('top-secret-value'), -1,
			'the password must never appear in the command arguments');
		assert.deepStrictEqual(call.args, [ 'apply-manual', 'network:wwan' ],
			'the wrapper must receive only the verb and the target');
		assert.strictEqual(call.env.APN_AUTOCONFIG_MANUAL_PASSWORD, 'top-secret-value',
			'the password must be passed through the environment instead');
		assert.strictEqual(call.env.APN_AUTOCONFIG_MANUAL_APN, 'internet.example',
			'the APN must be passed through the environment');
		assert.strictEqual(secretApp.manualPassword.value, '',
			'the password field must be cleared once the operation was accepted');

		/* Optional fields are omitted rather than sent empty. */
		var minimalApp = manualApp(function() {
			return { code: 0, stdout: JSON.stringify({ accepted: true, busy: true }) };
		});
		minimalApp.manualApn.value = 'plain.example';
		return Promise.resolve(minimalApp.startManualApn(minimalApp.manualApnValues())).then(function() {
			var env = minimalApp.testExecCalls[minimalApp.testExecCalls.length - 1].env;
			assert.deepStrictEqual(Object.keys(env), [ 'APN_AUTOCONFIG_MANUAL_APN' ],
				'a profile without credentials must not send empty credential values');
		});
	}).then(function() {
		/* Invalid input is refused in the browser, before anything is started. */
		var cases = [
			{ apn: '', why: 'an empty APN' },
			{ apn: 'bad apn', why: 'an APN with a space' },
			{ apn: 'bad/apn', why: 'an APN with a slash' },
			{ apn: 'ok.example', username: 'someone', why: 'a username without a password' },
			{ apn: 'ok.example', password: 'secret', why: 'a password without a username' }
		];
		cases.forEach(function(testCase) {
			var app = manualApp();
			app.manualApn.value = testCase.apn;
			app.manualUsername.value = testCase.username || '';
			app.manualPassword.value = testCase.password || '';
			app.confirmManualApn();
			assert.strictEqual(app.testExecCalls.length, 0,
				'nothing may be started for ' + testCase.why);
			assert.strictEqual(app.testUi.modals.length, 0,
				'no confirmation may be shown for ' + testCase.why);
			assert.ok(app.testUi.notifications.length > 0,
				testCase.why + ' must be explained to the user');
		});

		/* Valid input is confirmed before it is applied. */
		var confirmApp = manualApp();
		confirmApp.manualApn.value = 'internet.example';
		confirmApp.confirmManualApn();
		assert.strictEqual(confirmApp.testUi.modals.length, 1,
			'a valid manual APN must be confirmed before it is applied');
		assert.strictEqual(confirmApp.testExecCalls.length, 0,
			'showing the confirmation must not start anything');

		/* Manual entry is the rare fallback, so it must not sit expanded on the
		 * page asking every user to fill it in. It lives behind a control. */
		var dialogApp = loadView();
		dialogApp.profileApplySupported = true;
		dialogApp.busy = false;
		assert.strictEqual(dialogApp.manualApn, undefined,
			'the manual APN fields must not exist before the control is activated');
		dialogApp.openManualApn();
		assert.strictEqual(dialogApp.testUi.modals.length, 1,
			'the manual APN control must open a dialog');
		assert.ok(dialogApp.manualApn && dialogApp.manualPassword,
			'the dialog must contain the profile fields');
		assert.strictEqual(dialogApp.testExecCalls.length, 0,
			'opening the dialog must not start anything');

		/* Cancelling writes nothing and keeps nothing. */
		var cancelBody = dialogApp.testUi.modals[0].children;
		var cancelButton = collectButtons(cancelBody).filter(function(button) {
			return collectText(button.children).join('').trim() === 'Cancel';
		})[0];
		assert.ok(cancelButton, 'the dialog must offer a way out');
		cancelButton.click();
		assert.strictEqual(dialogApp.testExecCalls.length, 0,
			'cancelling the dialog must not start anything');
		assert.strictEqual(dialogApp.manualPassword, null,
			'cancelling must not keep the password field around');

		/* A target that cannot apply a profile never reaches the dialog. */
		var unsupported = loadView();
		unsupported.profileApplySupported = false;
		unsupported.busy = false;
		unsupported.openManualApn();
		assert.strictEqual(unsupported.testUi.modals.length, 0,
			'manual entry must not open for a target that cannot apply a profile');
	}).then(function() {
	/* ---- transport: a refusal arrives with a non-zero exit code ---- */

	/* provision-plan carries its refusal class in the exit status while still
	 * printing a complete answer. Treating that as a failure once put the raw
	 * JSON on the page, unmasked modem identity included. */
	var planApp = loadView(function(command, args) {
		if (args[0] === 'inventory')
			return { code: 0, stdout: JSON.stringify({
				version: 'v1',
				modems: [ { modem_id: 'usb-serial:1-1.2:2c7c:0801:SERIAL01', protocol: 'qmi' } ]
			}) };
		if (args[0] === 'provision-plan')
			return { code: 4, stdout: JSON.stringify({
				version: 'v1',
				modem_id: 'usb-serial:1-1.2:2c7c:0801:SERIAL01',
				can_provision: false,
				reason: 'already_configured',
				section: '',
				existing_section: '',
				protocol: '',
				device: ''
			}) };
		return { code: 0, stdout: JSON.stringify({ busy: false, state: 'idle' }) };
	});
	planApp.modemBox = element('div');
	return Promise.resolve(planApp.refreshProvisioning()).then(function() {
		var plan = planApp.modemInventory.modems[0].plan;
		assert.strictEqual(plan.reason, 'already_configured',
			'a refusal delivered with a non-zero exit code must be read as a result');
		assert.ok(!plan.error,
			'a complete answer must not be turned into an error by its exit code');

		var rendered = collectText(planApp.modemBox.children).join(' ');
		assert.strictEqual(rendered.indexOf('can_provision'), -1,
			'raw command output must never be rendered into the page');
		assert.strictEqual(rendered.indexOf('SERIAL01'), -1,
			'a refusal must not leak the unmasked modem identity');
		assert.ok(rendered.indexOf('belongs to a network interface you created') !== -1,
			'a refused modem must get its plain-language explanation');

		/* Output that is not an answer at all is still reported, without
		 * echoing whatever the command printed. */
		var brokenApp = loadView(function(command, args) {
			if (args[0] === 'inventory')
				return { code: 0, stdout: JSON.stringify({
					version: 'v1',
					modems: [ { modem_id: 'usb-serial:1-1.2:2c7c:0801:SERIAL01' } ]
				}) };
			if (args[0] === 'provision-plan')
				return { code: 127, stdout: 'usb-serial:1-1.2:2c7c:0801:SERIAL01 exploded' };
			return { code: 0, stdout: JSON.stringify({ busy: false, state: 'idle' }) };
		});
		brokenApp.modemBox = element('div');
		return Promise.resolve(brokenApp.refreshProvisioning()).then(function() {
			var brokenText = collectText(brokenApp.modemBox.children).join(' ');
			assert.strictEqual(brokenText.indexOf('exploded'), -1,
				'raw command output must not reach the page even when it fails');
			assert.strictEqual(brokenText.indexOf('SERIAL01'), -1,
				'a failed check must not leak the unmasked modem identity');
			assert.ok(brokenText.indexOf('could not run') !== -1,
				'a failed check must still be reported');
		});
	}).then(function() {
	console.log('LuCI provisioning card regression tests passed.');
	});
	});
}).catch(function(error) {
	console.error(error && error.stack || String(error));
	process.exit(1);
});
