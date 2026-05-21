COPY (
  SELECT status, COUNT(*) AS count
  FROM customer_deployments
  GROUP BY status
  ORDER BY status
) TO STDOUT WITH CSV HEADER;
