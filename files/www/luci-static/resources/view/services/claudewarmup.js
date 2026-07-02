'use strict';
'require view';

return view.extend({
	load: function() {
		window.location.replace('/claudewarmup/');
		return null;
	},
	render: function() {
		return E('p', {}, _('Redirecting…'));
	}
});
