export type PublicRegionHealth = 'operational' | 'degraded' | 'outage' | 'unknown';

export type PublicRegionUtilization = 'green' | 'yellow' | 'red';

export interface PublicTopologyCounts {
	healthy_count: number;
	unhealthy_count: number;
	unknown_count: number;
}

export interface PublicRegionInfrastructure extends PublicTopologyCounts {
	region: string;
	provider: string;
	display_name: string;
	provider_location: string;
	health: PublicRegionHealth;
	utilization: PublicRegionUtilization | null;
	vm_count: number;
}

export interface PublicInfrastructureOverall extends PublicTopologyCounts {
	availability_pct: number | null;
	total_regions: number;
	total_vms: number;
}

export interface PublicInfrastructureResponse {
	regions: PublicRegionInfrastructure[];
	overall: PublicInfrastructureOverall;
}
