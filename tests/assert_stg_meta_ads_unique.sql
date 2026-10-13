-- Falla si alguna combinación de fecha + campaña aparece más de una vez
select
    report_date,
    campaign_id,
    count(*) as filas
from {{ ref('stg_meta_ads') }}
group by report_date, campaign_id
having count(*) > 1