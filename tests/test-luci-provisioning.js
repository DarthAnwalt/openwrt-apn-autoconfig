'use strict';

/* Regression tests for the LuCI first-run provisioning card.
 *
 * These assert the safety properties the view is responsible for: a control is
 * never offered for something that cannot work, an interface the user created
 * is never offered for adoption or removal, the privileged wrapper is only ever
 * given a fixed verb and a modem identity, and a lost launch answer never
 * reports success. */

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
		exec: function(command, args) {
			execCalls.push({ command: command, args: args });
			var handled = execHandler ? execHandler(command, args) : null;
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

/* An unconfigured modem is the only case that offers setup. */
var app = loadView();
var setupNodes = app.provisioningNodes({
	version: 'v1',
	modems: [ modemFixture({ can_provision: true, reason: 'ok', section: 'apnmodem1', protocol: 'qmi' }) ]
});
assert.deepStrictEqual(buttonLabels(setupNodes), [ 'Set up this modem' ],
	'an unconfigured modem must offer exactly one setup control');
assert.ok(collectText(setupNodes).join(' ').indexOf('SERIAL01') === -1,
	'the modem identity must stay masked until the user reveals it');
assert.ok(collectText(setupNodes).join(' ').indexOf('apnmodem1') !== -1,
	'the view must name the interface it would create before the user agrees');

/* A modem belonging to an interface the user created is never offered for
 * adoption, removal or connection control. */
[ 'already_configured', 'ambiguous', 'conflicting_owner', 'unsupported_protocol', 'no_device' ]
	.forEach(function(reason) {
		var nodes = loadView().provisioningNodes({
			version: 'v1',
			modems: [ modemFixture({ can_provision: false, reason: reason }) ]
		});
		assert.deepStrictEqual(buttonLabels(nodes), [],
			'a modem refused for ' + reason + ' must offer no controls at all');
		assert.ok(collectText(nodes).join(' ').trim().length > 0,
			'a modem refused for ' + reason + ' must be explained instead of silently empty');
	});

/* A modem this package set up gets connection control and removal. */
var ownedNodes = loadView().provisioningNodes({
	version: 'v1',
	modems: [ modemFixture({ can_provision: false, reason: 'already_provisioned', existing_section: 'apnmodem1' }) ]
});
assert.deepStrictEqual(buttonLabels(ownedNodes),
	[ 'Connect', 'Reconnect', 'Disconnect', 'Remove setup' ],
	'a project-owned modem must offer connection control and removal');

/* A missing optional package explains itself rather than showing dead buttons. */
var absentNodes = loadView().provisioningNodes({ error: 'not installed' });
assert.deepStrictEqual(buttonLabels(absentNodes), [],
	'an absent modem package must not render controls');
assert.ok(collectText(absentNodes).join(' ').indexOf('apn-autoconfig-modem') !== -1,
	'an absent modem package must be named in the explanation');

/* Controls stay disabled while that modem already has an operation running. */
var busyNodes = loadView().provisioningNodes({
	version: 'v1',
	modems: [ modemFixture(
		{ can_provision: false, reason: 'already_provisioned', existing_section: 'apnmodem1' },
		{ busy: true, state: 'running' }
	) ]
});
assert.ok(actionButtons(busyNodes).every(function(button) { return button.disabled === true; }),
	'controls must be disabled while an operation is running for that modem');

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
	var owned = modemFixture({ can_provision: false, reason: 'already_provisioned', existing_section: 'apnmodem1' });
	[ 'provision', 'deprovision', 'disconnect', 'reconnect' ].forEach(function(verb) {
		confirmApp.confirmModemAction(owned, verb);
	});
	assert.strictEqual(confirmApp.testUi.modals.length, 4,
		'every state-changing verb must be confirmed first');
	assert.strictEqual(confirmApp.testExecCalls.length, 0,
		'showing a confirmation must not start anything');

	console.log('LuCI provisioning card regression tests passed.');
}).catch(function(error) {
	console.error(error && error.stack || String(error));
	process.exit(1);
});
