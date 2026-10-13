-- SILVER: tipos correctos, texto limpio y sin duplicados

with bronze as (

    select * from {{ ref('bronze_meta_ads') }}

),

typed as (

    select
        safe_cast(date as date)                      as report_date,
        safe_cast(campaign_id as int64)              as campaign_id,
        trim(campaign_name)                          as campaign_name,
        upper(trim(country))                         as country_code,
        coalesce(safe_cast(impressions as int64), 0) as impressions,
        coalesce(safe_cast(clicks as int64), 0)      as clicks,
        coalesce(safe_cast(spend as numeric), 0)     as spend,
        safe_cast(_loaded_at as timestamp)           as loaded_at
    from bronze

),

deduped as (

    -- Si la misma fila llegó dos veces, nos quedamos con la carga más reciente
    select *
    from typed
    qualify row_number() over (
        partition by report_date, campaign_id
        order by loaded_at desc
    ) = 1

)

select * from deduped