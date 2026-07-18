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

	var node = { tag: tag, attrs: {}, children: children, style: {} };
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

function descendants(node) {
	if (node == null || typeof node !== 'object')
		return [];
	var children = Array.isArray(node.children) ? node.children : [];
	return [ node ].concat(children.reduce(function(all, child) {
		return all.concat(descendants(child));
	}, []));
}

async function verifyLayout() {
	var app = loadView();
	var status = {
		version: 'v2',
		roaming_policy: 'default-allow',
		interface: 'wwan',
		interface_up: true,
		operator_name: 'Fixture Mobile',
		home_operator_name: 'Fixture Home',
		home_operator_id: '26201',
		serving_operator_name: 'Fixture Network',
		serving_operator_id: '26202',
		registration_state: 'home',
		access_technologies: 'lte,5gnr',
		signal_quality: '81',
		configured_apn: 'fixture.apn',
		database_format: '2',
		database_sources: 'fixture',
		database_revisions: 'fixture@1234567',
		database_path: '/usr/share/apn-autoconfig/providers.tsv'
	};
	var database = {
		state: 'update-available',
		installed_package_version: '2026.07.16-r1',
		database_version: '2026.07.16',
		database_format: '2',
		available_package_version: '2026.07.18-r1',
		checked_at: '2026-07-18T10:00:00Z',
		installed_at: '',
		feed_configured: true,
		key_trusted: true,
		update_available: true,
		feed_url: 'https://example.invalid/packages.adb',
		message: 'Update available'
	};
	var page = await app.render([ {}, status, { state: 'idle', busy: false }, database ]);
	var nodes = descendants(page);
	var headings = nodes.filter(function(node) { return node.tag === 'h3'; }).map(function(node) {
		return node.children.join('');
	});
	[ 'Mobile connection', 'Current APN', 'Provider database', 'Roaming data policy', 'Actions' ].forEach(function(heading) {
		assert.ok(headings.indexOf(heading) !== -1, 'missing grouped section: ' + heading);
	});
	assert.ok(nodes.some(function(node) {
		return node.attrs && (node.attrs['class'] || '').split(' ').indexOf('cbi-progressbar') !== -1;
	}), 'signal quality must use the native LuCI progress bar');
	assert.ok(!nodes.some(function(node) {
		return node.attrs && (node.attrs['class'] || '').split(' ').indexOf('apn-signal-value') !== -1;
	}), 'signal percentage must not be duplicated beside LuCI\'s native progress label');
	assert.ok(nodes.some(function(node) {
		return node.tag === 'strong' && node.children.join('') === 'Signal quality';
	}), 'status row labels must be bold');
	assert.strictEqual(app.databaseInstallButton.style.display, '',
		'Install update must be visible when an update is available');
	assert.strictEqual(app.databaseInstallButton.disabled, false,
		'Install update must be enabled when no operation is busy');
	assert.strictEqual(app.databaseCheckButton.disabled, false,
		'Check for updates must be enabled when no operation is busy');
	app.confirmDatabaseInstall();
	assert.strictEqual(app.testUi.modalCalls, 1,
		'database installation must require confirmation');
}

Promise.all([
	verifyPolicy('default-allow', 'default'),
	verifyPolicy('explicit-allow', 'allow'),
	verifyPolicy('explicit-block', 'block'),
	verifyLayout()
]).then(function() {
	process.stdout.write('LuCI layout and roaming policy regression tests passed.\n');
}).catch(function(error) {
	process.stderr.write(error.stack + '\n');
	process.exit(1);
});
