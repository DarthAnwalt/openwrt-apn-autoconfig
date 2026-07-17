'use strict';

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

	var node = { tag: tag, attrs: {}, children: children };
	Object.keys(attrs).forEach(function(key) {
		var value = attrs[key];
		if (value == null)
			return;
		if (typeof value === 'function')
			node[key] = value;
		else
			node.attrs[key] = String(value);
	});

	if (tag === 'option') {
		node.value = node.attrs.value;
		node.selected = Object.prototype.hasOwnProperty.call(node.attrs, 'selected');
	}

	if (tag === 'select') {
		node.options = children;
		var selected = children.filter(function(option) { return option.selected; });
		var current = selected.length ? selected[selected.length - 1].value : children[0].value;
		Object.defineProperty(node, 'value', {
			get: function() { return current; },
			set: function(value) {
				current = value;
				children.forEach(function(option) { option.selected = option.value === value; });
			}
		});
	}

	return node;
}

var brokenBooleanSelection = element('select', {}, [
	element('option', { value: 'default', selected: true }),
	element('option', { value: 'allow', selected: false }),
	element('option', { value: 'block', selected: false })
]);
assert.strictEqual(brokenBooleanSelection.value, 'block',
	'the test harness must reproduce LuCI serializing selected=false as a present HTML attribute');

function makeForm() {
	function option() {
		return { value: function() {} };
	}
	function section() {
		return {
			tab: function() {},
			taboption: option
		};
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

function loadView() {
	var view = { extend: function(value) { return value; } };
	var ui = {
		modalCalls: 0,
		hideModal: function() {},
		showModal: function() { this.modalCalls++; },
		addNotification: function() {}
	};
	var app = Function('view', 'form', 'fs', 'uci', 'ui', 'poll', 'dom', 'E', '_', source)(
		view,
		makeForm(),
		{},
		{},
		ui,
		{ add: function() {} },
		{ content: function(node, children) { node.children = children; } },
		element,
		function(value) { return value; }
	);
	app.testUi = ui;
	return app;
}

async function verifyPolicy(roamingPolicy, expectedValue) {
	var app = loadView();
	var status = {
		version: 'v2',
		roaming_policy: roamingPolicy,
		interface: 'wwan'
	};
	var action = { state: 'idle', busy: false };

	await app.render([ {}, status, action ]);

	assert.strictEqual(app.policySelect.value, expectedValue,
		'initial policy selection must match status before the first poll');
	assert.deepStrictEqual(app.policySelect.options.filter(function(option) {
		return option.selected;
	}).map(function(option) { return option.value; }), [ expectedValue ],
		'exactly one policy option must be selected');
	assert.strictEqual(app.policyButton.disabled, true,
		'Apply must remain disabled until the user deliberately changes the policy');
	app.confirmRoamingPolicy();
	assert.strictEqual(app.testUi.modalCalls, 0,
		'the confirmation path must also reject an unchanged policy');

	app.policySelect.change();
	assert.strictEqual(app.policyButton.disabled, false,
		'deliberately changing the policy must enable Apply');
	app.confirmRoamingPolicy();
	assert.strictEqual(app.testUi.modalCalls, 1,
		'a deliberate policy change must reach the confirmation dialog');
}

Promise.all([
	verifyPolicy('default-allow', 'default'),
	verifyPolicy('explicit-allow', 'allow'),
	verifyPolicy('explicit-block', 'block')
]).then(function() {
	process.stdout.write('LuCI roaming policy regression test passed.\n');
}).catch(function(error) {
	process.stderr.write(error.stack + '\n');
	process.exit(1);
});
