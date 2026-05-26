import { dev } from "$app/environment";
import { error } from "@sveltejs/kit";

export const load = async () => {
  if (!dev) {
    error(404, "Not found");
  }

  return {
    devMode: true
  };
};
