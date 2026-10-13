-- GOLD: una fila por campaña con KPIs listos para el dashboard

with silver as (

    select * from {{ ref('stg_meta_ads') }}

)

select
    campaign_id,
    campaign_name,
    country_code,
    min(report_date)                                  as first_date,
    max(report_date)                                  as last_date,
    sum(impressions)                                  as impressions,
    sum(clicks)                                       as clicks,
    sum(spend)                                        as spend,
    safe_divide(sum(clicks), sum(impressions))        as ctr,
    safe_divide(sum(spend), sum(clicks))              as cpc,
    safe_divide(sum(spend), sum(impressions)) * 1000  as cpm
from silver
group by campaign_id, campaign_name, country_code