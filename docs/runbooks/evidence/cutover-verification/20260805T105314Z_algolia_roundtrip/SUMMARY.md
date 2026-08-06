# Algolia Cutover Roundtrip Evidence

- verdict: pass
- step: verify_restored_match
- record_count: 3
- source_index: fjcloud-cutover-probe-20260805105314-13933
- destination_index: fjcloud-cutover-destination-20260805105314-13933
- deletion_proof_exact_source_absent: true

## Expected Report

```json
{
  "destinationIndex": "fjcloud-cutover-destination-20260805105314-13933",
  "queries": [
    {
      "destinationOnly": [],
      "hits": [
        {
          "destinationRank": 1,
          "objectID": "doc-alpha",
          "rankDelta": 0,
          "sourceRank": 1
        }
      ],
      "overlapCount": 1,
      "query": "uniquealpha",
      "sourceOnly": []
    },
    {
      "destinationOnly": [],
      "hits": [
        {
          "destinationRank": 1,
          "objectID": "doc-shared",
          "rankDelta": 0,
          "sourceRank": 1
        }
      ],
      "overlapCount": 1,
      "query": "uniqueshared",
      "sourceOnly": []
    }
  ],
  "resultLimit": 3,
  "sourceIndex": "fjcloud-cutover-probe-20260805105314-13933"
}
```

## Observed Match Report

```json
{
  "destinationIndex": "fjcloud-cutover-destination-20260805105314-13933",
  "queries": [
    {
      "destinationOnly": [],
      "hits": [
        {
          "destinationRank": 1,
          "objectID": "doc-alpha",
          "rankDelta": 0,
          "sourceRank": 1
        }
      ],
      "overlapCount": 1,
      "query": "uniquealpha",
      "sourceOnly": []
    },
    {
      "destinationOnly": [],
      "hits": [
        {
          "destinationRank": 1,
          "objectID": "doc-shared",
          "rankDelta": 0,
          "sourceRank": 1
        }
      ],
      "overlapCount": 1,
      "query": "uniqueshared",
      "sourceOnly": []
    }
  ],
  "resultLimit": 3,
  "sourceIndex": "fjcloud-cutover-probe-20260805105314-13933"
}
```

## Mutation Mismatch Report

```json
{
  "destinationIndex": "fjcloud-cutover-destination-20260805105314-13933",
  "queries": [
    {
      "destinationOnly": [
        "doc-alpha"
      ],
      "hits": [],
      "overlapCount": 0,
      "query": "uniquealpha",
      "sourceOnly": [
        "doc-mutated"
      ]
    },
    {
      "destinationOnly": [],
      "hits": [
        {
          "destinationRank": 1,
          "objectID": "doc-shared",
          "rankDelta": 0,
          "sourceRank": 1
        }
      ],
      "overlapCount": 1,
      "query": "uniqueshared",
      "sourceOnly": []
    }
  ],
  "resultLimit": 3,
  "sourceIndex": "fjcloud-cutover-probe-20260805105314-13933"
}
```

## Restored Match Report

```json
{
  "destinationIndex": "fjcloud-cutover-destination-20260805105314-13933",
  "queries": [
    {
      "destinationOnly": [],
      "hits": [
        {
          "destinationRank": 1,
          "objectID": "doc-alpha",
          "rankDelta": 0,
          "sourceRank": 1
        }
      ],
      "overlapCount": 1,
      "query": "uniquealpha",
      "sourceOnly": []
    },
    {
      "destinationOnly": [],
      "hits": [
        {
          "destinationRank": 1,
          "objectID": "doc-shared",
          "rankDelta": 0,
          "sourceRank": 1
        }
      ],
      "overlapCount": 1,
      "query": "uniqueshared",
      "sourceOnly": []
    }
  ],
  "resultLimit": 3,
  "sourceIndex": "fjcloud-cutover-probe-20260805105314-13933"
}
```

## Sanitized Follow-Up List Indexes

```json
{"items":[]}
```
