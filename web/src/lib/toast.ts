import { Toaster, toast } from 'svelte-sonner';
import type { ToasterProps } from 'svelte-sonner';
import { TOAST_DURATION_MS } from './toast_contract';

export { Toaster, toast };
export { TOAST_DURATION_MS };

export const toasterProps = {
	position: 'bottom-right',
	duration: TOAST_DURATION_MS,
	closeButton: true,
	containerAriaLabel: 'Notifications',
	toastOptions: {
		class: 'border border-flapjack-ink/20 bg-white text-flapjack-ink shadow-elevation-card',
		descriptionClass: 'text-flapjack-ink/70',
		classes: {
			success: 'border-flapjack-mint/60 bg-flapjack-mint/25 text-flapjack-ink',
			info: 'border-flapjack-ink/20 bg-white text-flapjack-ink',
			warning: 'border-flapjack-yellow/50 bg-flapjack-yellow/20 text-flapjack-ink',
			error: 'border-flapjack-rose/35 bg-flapjack-rose/10 text-flapjack-plum',
			actionButton:
				'rounded-md border-2 border-flapjack-ink bg-brand-pink px-3 py-1.5 text-sm font-bold text-flapjack-ink shadow-elevation-button hover:bg-flapjack-plum/80',
			cancelButton:
				'rounded-md border border-flapjack-ink/30 bg-white px-3 py-1.5 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80',
			closeButton:
				'border border-flapjack-ink/30 bg-white text-flapjack-ink hover:bg-flapjack-cream'
		}
	}
} satisfies ToasterProps;
